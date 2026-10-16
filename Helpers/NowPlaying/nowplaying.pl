#!/usr/bin/perl
# Loads Sidekick's NowPlayingAdapter.dylib into the system perl (allowed to use MediaRemote) and runs one entry point.
use strict;
use DynaLoader;
my ($lib, $mode) = @ARGV;
my $h = DynaLoader::dl_load_file($lib, 0) or die "load failed: " . DynaLoader::dl_error() . "\n";
my $s = DynaLoader::dl_find_symbol($h, "sidekick_" . ($mode || "get")) or die "no entry point\n";
DynaLoader::dl_install_xsub("main::run", $s);
main::run();
