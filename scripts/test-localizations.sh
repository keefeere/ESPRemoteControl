#!/bin/bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
main_english="$repo_root/InpuDeck/en.lproj/Localizable.strings"
share_english="$repo_root/InpuDeckShare/en.lproj/Localizable.strings"

for strings_file in \
  "$repo_root"/InpuDeck/{en,uk}.lproj/*.strings \
  "$repo_root"/InpuDeckShare/{en,uk}.lproj/*.strings; do
  if command -v plutil >/dev/null; then
    plutil -lint "$strings_file" >/dev/null
  else
    awk '
      /^[[:space:]]*($|\/\*|\*|\/\/)/ { next }
      !/^"([^"\\]|\\.)*"[[:space:]]*=[[:space:]]*"([^"\\]|\\.)*";[[:space:]]*$/ {
        print FILENAME ":" NR ": invalid .strings syntax: " $0
        failed = 1
      }
      END { exit failed }
    ' "$strings_file"
  fi
done

perl -CSDA - "$main_english" "$share_english" <<'PERL'
use strict;
use warnings;
use utf8;

for my $strings_path (@ARGV) {
    open my $strings, '<:encoding(UTF-8)', $strings_path or die "$strings_path: $!\n";
    my $line_number = 0;
    while (<$strings>) {
        ++$line_number;
        next unless /^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";/;
        my ($key, $value) = ($1, $2);
        my @key_placeholders = ($key =~ /%(?:\d+\$)?(?:@|d)/g);
        my @value_placeholders = ($value =~ /%(?:\d+\$)?(?:@|d)/g);
        die "$strings_path:$line_number: format placeholder mismatch\n"
            unless @key_placeholders == @value_placeholders;
    }
}
PERL

# Existing UI is predominantly Ukrainian. Require every Ukrainian string
# literal (apart from keyboard character tables) to have an English entry.
perl -CSDA - "$main_english" "$repo_root"/InpuDeck/*.swift "$repo_root"/Shared/*.swift <<'PERL'
use strict;
use warnings;
use utf8;

my $strings_path = shift @ARGV;
open my $strings, '<:encoding(UTF-8)', $strings_path or die "$strings_path: $!\n";
my %english_keys;
while (<$strings>) {
    $english_keys{$1} = 1 if /^"((?:[^"\\]|\\.)*)"\s*=/;
}

my @missing;
for my $source_path (@ARGV) {
    open my $source, '<:encoding(UTF-8)', $source_path or die "$source_path: $!\n";
    my $line_number = 0;
    while (<$source>) {
        ++$line_number;
        while (/"((?:[^"\\]|\\.)*[А-Яа-яІіЇїЄєҐґ](?:[^"\\]|\\.)*)"/g) {
            my $key = $1;
            next if $key =~ /^[А-Яа-яІіЇїЄєҐґЁёЪъЫыЭэ]+$/;
            $key =~ s/\\\([^)]*\)/%@/g;
            push @missing, "$source_path:$line_number: $key" unless $english_keys{$key};
        }
    }
}

die "Missing English localization keys:\n", join("\n", @missing), "\n" if @missing;
PERL

# The Share Extension is a separate bundle and therefore has its own table.
perl -CSDA - "$share_english" "$repo_root"/InpuDeckShare/*.swift <<'PERL'
use strict;
use warnings;
use utf8;

my $strings_path = shift @ARGV;
open my $strings, '<:encoding(UTF-8)', $strings_path or die "$strings_path: $!\n";
my %english_keys;
while (<$strings>) {
    $english_keys{$1} = 1 if /^"((?:[^"\\]|\\.)*)"\s*=/;
}

my @missing;
for my $source_path (@ARGV) {
    open my $source, '<:encoding(UTF-8)', $source_path or die "$source_path: $!\n";
    my $line_number = 0;
    while (<$source>) {
        ++$line_number;
        while (/"((?:[^"\\]|\\.)*[А-Яа-яІіЇїЄєҐґ](?:[^"\\]|\\.)*)"/g) {
            my $key = $1;
            $key =~ s/\\\([^)]*\)/%@/g;
            push @missing, "$source_path:$line_number: $key" unless $english_keys{$key};
        }
    }
}

die "Missing Share Extension English localization keys:\n", join("\n", @missing), "\n" if @missing;
PERL

echo "English and Ukrainian localization resources are valid and complete."
