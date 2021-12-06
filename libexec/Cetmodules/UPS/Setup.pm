# -*- cperl -*-
package Cetmodules::UPS::Setup;

use 5.016;

use English qw(-no_match_vars);
use Exporter qw(import);
use File::Spec;
use IO::File;
use List::MoreUtils;
use Readonly;

use Cetmodules qw(:DIAG_VARS);
use Cetmodules::CMake;
use Cetmodules::UPS::ProductDeps qw(:DEFAULT $BTYPE_TABLE $PATHSPEC_INFO);
use Cetmodules::Util;
use Cetmodules::Util::VariableSaver;

use strict;
use warnings FATAL => qw(
  Cetmodules
  io
  regexp
  severe
  syntax
  uninitialized
  void
);

our (@EXPORT);

@EXPORT = qw(
  cetpkg_info_file
  classify_deps
  compiler_for_quals
  deps_for_quals
  get_cmake_project_info
  get_derived_parent_data
  match_qual
  output_info
  print_dep_setup
  print_dep_setup_one
  print_dev_setup
  print_dev_setup_var
  table_dep_setup
  ups_to_cmake
  write_table_deps
  write_table_frag
);

########################################################################
# Private variables for use within this module only
########################################################################

my ($_cqual_table, $_seen_cet_cmake_env, $_seen_project);

Readonly::Scalar my $_EXEC_MODE => oct(755);

########################################################################
# Exported functions
########################################################################

# Output information for buildtool.
sub cetpkg_info_file {
  my (%info) = @_;

  my @expected_keys = qw(source build name version cmake_project_version
    chains qualspec cqual build_type extqual use_time_deps
    build_only_deps cmake_args);
  my @for_export = (qw(CETPKG_SOURCE CETPKG_BUILD));
  my $cetpkgfile =
    File::Spec->catfile($info{build} || q(.), "cetpkg_info.sh");
  my $fh = IO::File->new("$cetpkgfile", q(>)) or
    error_exit("couldn't open $cetpkgfile for write");
  $fh->print(<<'EOD');
#!/bin/bash
########################################################################
# cetpkg_info.sh
#
#   Generated script to define variables required by buildtool to
#   compose the build environment.
#
# If we're being sourced, define the expected shell and environment
# variables; otherwise, print the definitions for user information.
#
##################
# NOTES
#
# * The definitions printed by executing this script are formatted to be
#   human-readable; they may *not* be suitable for feeding to a shell.
#
# * This script is *not* shell-agnostic, as it is not intended to be a 
#   general setup script.
#
# * Most items are not exported to the environment and will therefore
#   not be visible downstream of the shell sourcing this file.
#
########################################################################

( return 0 2>/dev/null ) && eval "__EOF__() { :; }" && \
  _cetpkg_catit=(:) || _cetpkg_catit=(cat '<<' __EOF__ '|' sed -Ee "'"'s&\\([^\\]|$)&\1&g'"'" )
eval "${_cetpkg_catit[@]}"$'\n'\
EOD
  my $var_data;
  my $tmp_fh = IO::File->new(\$var_data, q(>)) or
    error_exit("could not open memory stream to variable \$tmp_fh");

  # Output known info in expected order, followed by any remainder in
  # lexical order.
  my @output_items = output_info(
    $tmp_fh,
    \%info,
    \@for_export,
    (map {
       my $key = $_;
       (grep { $key eq $_ } keys %info) ? ($key) : ()
       } @expected_keys
    ),
    (map {
       my $key = $_;
       (grep { $key eq $_ } @expected_keys) ? () : ($key)
       } sort keys %info
    ));
  $tmp_fh->close();
  $tmp_fh->open(\$var_data, q(<)) or
    error_exit("unable to open memory stream from variable \$tmp_fh");
  while (<$tmp_fh>) {
    chomp;
    $fh->print("\Q$_\E\$'\\n'\\\n");
  }
  $tmp_fh->close();
  $fh->print(<<'EOD');
$'\n'\
__EOF__
( return 0 2>/dev/null ) && unset __EOF__ \
EOD
  $fh->print("  || true\n");
  $fh->close();
  chmod $_EXEC_MODE, $cetpkgfile;
  return $cetpkgfile;
} ## end sub cetpkg_info_file


sub classify_deps {
  my ($pi, $dep_info) = @_;
  foreach my $dep (sort keys %{$dep_info}) {
    $pi->{ ($dep_info->{$dep}->{only_for_build}) ? 'build_only_deps' :
        'use_time_deps' }->{$dep} = 1;
  }
  foreach my $key (qw(build_only_deps use_time_deps)) {
    $pi->{$key} = [ sort keys %{ $pi->{$key} } ];
  }
  return;
} ## end sub classify_deps


sub compiler_for_quals {
  my ($compilers, $qualspec) = @_;

  $compilers->{$qualspec} and
    $compilers->{$qualspec} ne q(-) and
    return $compilers->{$qualspec};

  my $compiler = 'cc'; # Default to native.
  given (${ sort_qual($qualspec) }[0] // q()) {
    when (m&\A(?:e13|c(?:lang)?\d+)\z&msx) {
      $compiler = "clang";
    }
    when (m&\A(?:e|gcc)\d+\z&msx) {
      $compiler = "gcc";
    }
    when (m&\A(?:i|icc)\d+\z&msx) {
      $compiler = "icc";
    }
  } ## end given
  return $compiler;
} ## end sub compiler_for_quals


sub deps_for_quals {
  my ($pfile, $phash, $qhash, $qualspec) = @_;
  my $results = {};
  foreach my $prod (sort keys %{$phash}) {

    # Find matching version hashes for this product, including default
    # and empty. $phash is the product list hash as produced by
    # get_product_list().
    my $matches = {
      map {
        match_qual($_, $qualspec) ? ($_ => $phash->{ ${prod} }->{$_}) : ();
      } sort keys %{ $phash->{$prod} } };

    # Remove the default entry from the set of matches (if it exists)
    # and save it.
    my $default = delete $matches->{"-default-"}; # undef if missing.
    scalar keys %{$matches} > 1 and error_exit(<<"EOF");
ambiguous result matching version for dependency $prod against parent qualifiers $qualspec
EOF

    # Use $default if we need to.
    my $result = (values %{$matches})[0] || $default || next;
    $result = { %{$result} }; # Copy contents for amendment.
    if (exists $qhash->{$prod} and exists $qhash->{$prod}->{$qualspec}) {
      if ($qhash->{$prod}->{$qualspec} eq '-b-') {

        # Old syntax for unqualified build-only deps.
        $result->{only_for_build} = 1;
        $result->{qualspec}       = q();
      } elsif ($qhash->{$prod}->{$qualspec} eq q(-)) {

        # Not needed here.
        next;
      } else {

        # Normal case.
        $result->{qualspec} = $qhash->{$prod}->{$qualspec} || q();
      }
    } elsif (not $result->{only_for_build}) {
      if (not exists $qhash->{$prod}) {
        error_exit("dependency $prod has no column in the qualifier table.",
                   "Please check $pfile");
      } else {
        error_exit(
             sprintf(
                  "dependency %s has no entry in the qualifier table for %s.",
                  $prod,
                  ($qualspec ? "parent qualifier $qualspec" :
                     "unqualified parent"
                  )
             ),
             "Please check $pfile");
      } ## end else [ if (not exists $qhash->...)]
    } else {
      $result->{qualspec} = $qhash->{$prod}->{$qualspec} || q();
    }
    $results->{$prod} = $result;
  } # foreach $prod.
  return $results;
} ## end sub deps_for_quals


sub get_cmake_project_info {
  my ($pkgtop, %options) = @_;
  undef $_seen_cet_cmake_env;
  undef $_seen_project;
  my $cmakelists = File::Spec->catfile($pkgtop, "CMakeLists.txt");
  my $proj_info = {
                    map { %{$_}; }
                      values %{
                      process_cmakelists(
                           $cmakelists, %options,
                           project_callback => \&_get_info_from_project_call,
                           set_callback     => \&_get_info_from_set_calls,
                           cet_cmake_env_callback => \&_set_seen_cet_cmake_env
                      ) } };
  return $proj_info;
} ## end sub get_cmake_project_info


sub get_derived_parent_data {
  my ($pi, $sourcedir, @qualstrings) = @_;

  # Checksum the absolute filename of the CMakeLists.txt file to
  # identify initial values for project variables when we're not
  # guaranteed to know the CMake project name by reading CMakeLists.txt
  # (conditionals, variables, etc.):
  $pi->{project_variable_prefix} = get_CMakeLists_hash($sourcedir);

  # CMake info.
  my $cpi =
    get_cmake_project_info($sourcedir,
                           ($pi->{version}) ? (quiet_warnings => 1) : ());

  if (not $cpi or not scalar keys %{$cpi}) {
    error_exit(
        "unable to obtain useful information from $sourcedir/CMakeLists.txt");
  }

  if (not defined $pi->{name}) {
    $cpi->{cmake_project_name} and
      not $cpi->{cmake_project_name} =~ m&\$&msx and
      $pi->{name} = to_product_name($cpi->{cmake_project_name}) or
      error_exit(<<"EOF");
UPS product name not specified in product_deps and could not identify an
unambiguous project name in $sourcedir/CMakeLists.txt
EOF
  }

  exists $cpi->{cmake_project_version_info} and
    $cpi->{cmake_project_version_info}->{extra} and
    error_exit(<<"EOF");
VERSION as specified in $sourcedir/CMakeLists.txt:project() ($cpi->{cmake_project_version}) has an
impermissible non-numeric component "$cpi->{cmake_project_version_info}->{extra}": remove from project()
and set \${PROJECT_NAME}_CMAKE_PROJECT_VERSION_STRING to $cpi->{cmake_project_version}
before calling cet_cmake_env()
EOF

  _set_version($pi, $cpi, $sourcedir);

  my @sorted;
  $pi->{qualspec} = sort_qual(\@sorted, @qualstrings);
  @{$pi}{qw(cqual extqual build_type)} = @sorted;
  $pi->{build_type} and
    $pi->{cmake_build_type} = $BTYPE_TABLE->{ $pi->{build_type} };

  # Derivatives of the product's UPS flavor.
  if ($pi->{no_fq_dir}) {
    $pi->{flavor} = "NULL";
  } else {
    my $flavor =
      qx(ups flavor -4) ## no critic qw(InputOutput::ProhibitBacktickOperator)
      or
      error_exit("failure executing ups flavor: UPS not set up?",
                 $OS_ERROR // ());
    chomp $flavor;

    # We only care about OS major version no. for Darwin.
    $flavor =~ s&\A(Darwin.*?\+\d+).*\z&${1}&msx;
    $pi->{flavor} = $flavor;
    my $fq_dir = ($pi->{noarch}) ? 'noarch' : $ENV{CET_SUBDIR} or
      error_exit("CET_SUBDIR not set: missing cetpkgsupport?");
    $pi->{fq_dir} = join(q(.), $fq_dir, split(/:/msx, $pi->{qualspec}));
  } ## end else [ if ($pi->{no_fq_dir}) ]
  return;
} ## end sub get_derived_parent_data


sub match_qual {
  my ($match_spec, $qualstring) = @_;
  my @quals = split(/:/msx, $qualstring);
  my ($neg, $qual_spec) = ($match_spec =~ m&\A(!)?(.*)\z&msx);
  return ($qual_spec eq q(-)          or
            $qual_spec eq '-default-' or
            ($neg xor grep { $qual_spec eq $_ } @quals));
}


sub output_info {
  my ($fh, $info, $for_export, @keys) = @_;
  my @defined_vars = ();
  foreach my $key (@keys) {
    my $var = "CETPKG_\U$key";
    List::MoreUtils::any { $var eq $_; } @{$for_export} and
      $var = "export $var";
    my $val = $info->{$key} || q();
    $fh->print("$var=");
    if (not ref $val) {
      $fh->print("\Q$val\E\n");
    } elsif (ref $val eq "SCALAR") {
      $fh->print("\Q$$val\E\n");
    } elsif (ref $val eq "ARRAY") {
      $fh->printf("(%s)\n", join(q( ), map { "\Q$_\E" } @{$val}));
    } else {
      verbose(sprintf("ignoring unexpected info $key of type %s", ref $val));
    }
    push @defined_vars, $var;
  } ## end foreach my $key (@keys)
  return @defined_vars;
} ## end sub output_info


sub print_dep_setup {
  my ($deps, $out) = @_;

  my ($setup_cmds, $only_for_build_cmds);

  # Temporary variable connected as a filehandle.
  my $setup_cmds_fh = IO::File->new(\$setup_cmds, q(>)) or
    error_exit("could not open memory stream to variable \$setup_cmds");

  # Second temporary variable connected as a filehandle.
  my $only_cmds_fh = IO::File->new(\$only_for_build_cmds, q(>)) or
    error_exit(
            "could not open memory stream to variable \$only_for_build_cmds");

  my $onlyForBuild = q();
  for (keys %{$deps}) {
    my $dep_info = $deps->{$_};
    my $fh;
    if ($dep_info->{only_for_build}) {
      m&\Acet(?:buildtools|modules)\z&msx and next; # Dealt with elsewhere.
      $fh = $only_cmds_fh;
    } else {
      $fh = $setup_cmds_fh;
    }
    print_dep_setup_one($_, $dep_info, $fh);
  } ## end for (keys %{$deps})
  $setup_cmds_fh->close();
  $only_cmds_fh->close();

  $out->print(<<'EOF');
# Add '-B' to UPS_OVERRIDE for safety.
tnotnull UPS_OVERRIDE || setenv UPS_OVERRIDE ''
expr "x $UPS_OVERRIDE" : '.* -[^- 	]*B' >/dev/null || setenv UPS_OVERRIDE "$UPS_OVERRIDE -B"
EOF

  # Build-time dependencies first.
  $only_for_build_cmds and $out->print(<<'EOF', $only_for_build_cmds);

####################################
# Build-time dependencies.
####################################
EOF

  # Now use-time dependencies.
  $setup_cmds and $out->print(<<'EOF', $setup_cmds);

####################################
# Use-time dependencies.
####################################
EOF

  return;
} ## end sub print_dep_setup


sub print_dep_setup_one {
  my ($dep, $dep_info, $out) = @_;
  my $thisver =
    (not $dep_info->{version} or $dep_info->{version} eq q(-)) ? q() :
    $dep_info->{version};
  my @setup_options =
    (exists $dep_info->{setup_options} and $dep_info->{setup_options}) ?
    @{ $dep_info->{setup_options} } :
    ();
  my @prodspec   = ("$dep", "$thisver");
  my $qualstring = join(q(:+), split(/:/msx, $dep_info->{qualspec} || q()));
  $qualstring and push @prodspec, '-q', $qualstring;
  $out->print("# > $dep <\n");
  if ($dep_info->{optional}) {
    my $prodspec_string = join(q( ), @prodspec);
    $out->print(<<"EOF");
# Setup of $dep is optional.
ups exist $prodspec_string
test "\$?" != 0 && \\
  echo \QINFO: skipping missing optional product $prodspec_string\E || \\
EOF
    $out->print(q(  ));
  } ## end if ($dep_info->{optional...})
  my $setup_cmd = join(q( ), qw(setup -B), @prodspec, @setup_options);
  if (scalar @setup_options) {

    # Work around bug in ups active -> unsetup_all for UPS<=6.0.8.
    $setup_cmd = sprintf(
         '%s && setenv %s "`echo \"$%s\" | sed -Ee \'s&[[:space:]]+-j$&&\'`"',
         "$setup_cmd", ("SETUP_\U$dep\E") x 2);
  }
  $out->print("$setup_cmd; ");
  _setup_err($out, "$setup_cmd failed");
  return;
} ## end sub print_dep_setup_one


sub print_dev_setup {
  my ($pi, $out) = @_;
  my $fqdir;
  $out->print(<<"EOF");

####################################
# Development environment.
####################################
EOF
  my $libdir = _fq_path_for($pi, 'libdir', 'lib');
  $libdir and _setup_from_libdir($pi, $out, $libdir);

  # ROOT_INCLUDE_PATH.
  $out->print(print_dev_setup_var("ROOT_INCLUDE_PATH",
                                  [qw(${CETPKG_SOURCE} ${CETPKG_BUILD})]));

  # CMAKE_PREFIX_PATH.
  $out->print(print_dev_setup_var("CMAKE_PREFIX_PATH", '${CETPKG_BUILD}', 1));

  # FHICL_FILE_PATH.
  $fqdir = _fq_path_for($pi, 'fcldir', 'fcl')
    and $out->print(
           print_dev_setup_var(
             "FHICL_FILE_PATH", File::Spec->catfile('${CETPKG_BUILD}', $fqdir)
                              ));

  # FW_SEARCH_PATH.
  my $fw_pathspec = get_pathspec($pi, 'set_fwdir');
  $fw_pathspec->{path} and
    not $fw_pathspec->{fq_path} and
    error_exit(<<"EOF");
INTERNAL ERROR in print_dev_setup(): ups_to_cmake() should have been called first
EOF
  my @fqdirs =
    map { m&\A/&msx ? $_ : File::Spec->catfile('${CETPKG_BUILD}', $_); } (
                                   _fq_path_for($pi, 'gdmldir', 'gdml') || (),
                                   _fq_path_for($pi, 'fwdir') || ());
  push @fqdirs,
    map { m&\A/&msx ? $_ : File::Spec->catfile('${CETPKG_SOURCE}', $_); }
    @{ $fw_pathspec->{fq_path} || [] };
  $out->print(print_dev_setup_var("FW_SEARCH_PATH", \@fqdirs));

  # WIRECELL_PATH.
  my $wp_pathspec = get_pathspec($pi, 'set_wpdir') || {};
  $wp_pathspec->{path} and
    not $wp_pathspec->{fq_path} and
    error_exit(<<"EOF");
INTERNAL ERROR in print_dev_setup(): ups_to_cmake() should have been called first
EOF

  @fqdirs =
    map { m&\A/&msx ? $_ : File::Spec->catfile('${CETPKG_SOURCE}', $_); }
    @{ $wp_pathspec->{fq_path} || [] };
  $out->print(print_dev_setup_var("WIRECELL_PATH", \@fqdirs));

  # PYTHONPATH.
  $pi->{define_pythonpath}
    and $out->print(
                print_dev_setup_var(
                  "PYTHONPATH",
                  File::Spec->catfile(
                    '${CETPKG_BUILD}', $libdir || ($pi->{fq_dir} || (), 'lib')
                                     )));

  # PATH.
  $fqdir = _fq_path_for($pi, 'bindir', 'bin')
    and $out->print(print_dev_setup_var(
                             "PATH",
                             [ File::Spec->catfile('${CETPKG_BUILD}', $fqdir),
                               File::Spec->catfile('${CETPKG_SOURCE}', $fqdir)
                             ]));
  return;
} ## end sub print_dev_setup


sub print_dev_setup_var {
  my ($var, $val, $no_errclause) = @_;
  my @vals = (ref $val eq 'ARRAY') ? @{$val} : ($val // ());
  my $result;
  my $out = IO::File->new(\$result, q(>)) or
    error_exit("could not open memory stream to variable \$out");
  if (scalar @vals) {
    $out->print("# $var\n",
                "setenv $var ",
                '"`dropit -p \\"${',
                "$var",
                '}\\" -sfe ');
    $out->print(join(q( ), map { sprintf('\\"%s\\"', $_); } @vals), q(`"));
    if ($no_errclause) {
      $out->print("\n");
    } else {
      $out->print("; ");
      _setup_err($out, "failure to prepend to $var");
    }
  } ## end if (scalar @vals)
  $out->close();
  return $result // q();
} ## end sub print_dev_setup_var


sub table_dep_setup {
  my ($dep, $dep_info, $fh) = @_;
  my @setup_cmd_args = ($dep,
                        ($dep_info->{version} ne '-c') ?
                          $dep_info->{version} : (),
                        $dep_info->{qualspec} ? (
                              '-q',
                              sprintf("+%s",
                                      join(
                                        q(:+),
                                        split(
                                          /:/msx, $dep_info->{qualspec} || q()
                                        )))
                          ) : ());
  $fh->printf("setup%s(%s)\n",
              ($dep_info->{optional}) ? "Optional" : "Required",
              join(q( ), @setup_cmd_args));
  return;
} ## end sub table_dep_setup


sub ups_to_cmake {
  my ($pi) = @_;

  (not $pi->{cqual})
    or
    (exists $_cqual_table->{ $pi->{cqual} }
     and my ($cc,               $cxx,          $compiler_id,
             $compiler_version, $cxx_standard, $fc,
             $fc_id,            $fc_version)
     = @{ $_cqual_table->{ $pi->{cqual} } } or
     error_exit("unrecognized compiler qualifier $pi->{cqual}"));

  my @cmake_args = ();

  ##################
  # UPS-specific CMake configuration.

  push @cmake_args, '-DWANT_UPS:BOOL=ON';
  $compiler_id and
    push @cmake_args, "-DUPS_C_COMPILER_ID:STRING=$compiler_id",
    "-DUPS_C_COMPILER_VERSION:STRING=$compiler_version",
    "-DUPS_CXX_COMPILER_ID:STRING=$compiler_id",
    "-DUPS_CXX_COMPILER_VERSION:STRING=$compiler_version",
    "-DUPS_Fortran_COMPILER_ID:STRING=$fc_id",
    "-DUPS_Fortran_COMPILER_VERSION:STRING=$fc_version";

  my $pv_prefix = "CET_PV_$pi->{project_variable_prefix}";

  push @cmake_args, _cmake_defs_for_ups_config($pi, $pv_prefix);

  ##################
  # General CMake configuration.
  push @cmake_args, "-DCET_PV_PREFIX:STRING=$pi->{project_variable_prefix}";
  $pi->{cmake_build_type} and
    push @cmake_args, "-DCMAKE_BUILD_TYPE:STRING=$pi->{cmake_build_type}";
  $compiler_id and
    push @cmake_args, "-DCMAKE_C_COMPILER:STRING=$cc",
    "-DCMAKE_CXX_COMPILER:STRING=$cxx",
    "-DCMAKE_Fortran_COMPILER:STRING=$fc",
    "-DCMAKE_CXX_STANDARD:STRING=$cxx_standard",
    "-DCMAKE_CXX_STANDARD_REQUIRED:BOOL=ON",
    "-DCMAKE_CXX_EXTENSIONS:BOOL=OFF";
  $pi->{fq_dir} and
    push @cmake_args, "-D${pv_prefix}_EXEC_PREFIX:STRING=$pi->{fq_dir}";
  $pi->{noarch} and push @cmake_args, "-D${pv_prefix}_NOARCH:BOOL=ON";
  $pi->{define_pythonpath} and
    push @cmake_args, "-D${pv_prefix}_DEFINE_PYTHONPATH:BOOL=ON";
  $pi->{old_style_config_vars} and
    push @cmake_args, "-D${pv_prefix}_OLD_STYLE_CONFIG_VARS:BOOL=ON";

  ##################
  # Pathspec-related CMake configuration.

  push @cmake_args,
    (map { _cmake_project_var_for_pathspec($pi, $_) || (); }
     keys %{$PATHSPEC_INFO});

  my @arch_pathspecs   = ();
  my @noarch_pathspecs = ();
  foreach my $pathspec (values %{ $pi->{pathspec_cache} }) {
    if ($pathspec->{var_stem} and
        not ref $pathspec->{path} and
        $pathspec->{key} ne q(-)) {
      push @{ $pathspec->{key} eq 'fq_dir' ? \@arch_pathspecs :
          \@noarch_pathspecs }, $pathspec->{var_stem};
    }
  }
  scalar @arch_pathspecs and push @cmake_args,
    sprintf("-D${pv_prefix}_ADD_ARCH_DIRS:INTERNAL=%s",
            join(q(;), @arch_pathspecs));
  scalar @noarch_pathspecs and push @cmake_args,
    sprintf("-D${pv_prefix}_ADD_NOARCH_DIRS:INTERNAL=%s",
            join(q(;), @noarch_pathspecs));

  ##################
  # Done.
  return \@cmake_args;
} ## end sub ups_to_cmake


sub write_table_deps {
  my ($parent, $deps) = @_;
  my $fh = IO::File->new("table_deps_$parent", q(>)) or
    error_exit("Unable to open table_deps_$parent for write");
  foreach my $dep (sort keys %{$deps}) {
    my $dep_info = $deps->{$dep};
    $dep_info->{only_for_build} or table_dep_setup($dep, $dep_info, $fh);
  }
  $fh->close();
  return;
} ## end sub write_table_deps


sub write_table_frag {
  my ($parent, $pfile) = @_;
  my $fraglines = get_table_fragment($pfile);
  if ($fraglines and scalar @{$fraglines}) {
    my $fh = IO::File->new("table_frag_$parent", q(>)) or
      error_exit("Unable to open table_frag_$parent for write");
    $fh->print(join("\n", @{$fraglines}), "\n");
    $fh->close();
  } else {
    unlink("table_frag_$parent");
  }
  return;
} ## end sub write_table_frag

########################################################################
# Private variables
########################################################################

$_cqual_table = {
  e2  => [ 'gcc', 'g++', 'GNU', '4.7.1',  '11', 'gfortran', 'GNU', '4.7.1' ],
  e4  => [ 'gcc', 'g++', 'GNU', '4.8.1',  '11', 'gfortran', 'GNU', '4.8.1' ],
  e5  => [ 'gcc', 'g++', 'GNU', '4.8.2',  '11', 'gfortran', 'GNU', '4.8.2' ],
  e6  => [ 'gcc', 'g++', 'GNU', '4.9.1',  '14', 'gfortran', 'GNU', '4.9.1' ],
  e7  => [ 'gcc', 'g++', 'GNU', '4.9.2',  '14', 'gfortran', 'GNU', '4.9.2' ],
  e8  => [ 'gcc', 'g++', 'GNU', '5.2.0',  '14', 'gfortran', 'GNU', '5.2.0' ],
  e9  => [ 'gcc', 'g++', 'GNU', '4.9.3',  '14', 'gfortran', 'GNU', '4.9.3' ],
  e10 => [ 'gcc', 'g++', 'GNU', '4.9.3',  '14', 'gfortran', 'GNU', '4.9.3' ],
  e14 => [ 'gcc', 'g++', 'GNU', '6.3.0',  '14', 'gfortran', 'GNU', '6.3.0' ],
  e15 => [ 'gcc', 'g++', 'GNU', '6.4.0',  '14', 'gfortran', 'GNU', '6.4.0' ],
  e17 => [ 'gcc', 'g++', 'GNU', '7.3.0',  '17', 'gfortran', 'GNU', '7.3.0' ],
  e19 => [ 'gcc', 'g++', 'GNU', '8.2.0',  '17', 'gfortran', 'GNU', '8.2.0' ],
  e20 => [ 'gcc', 'g++', 'GNU', '9.3.0',  '17', 'gfortran', 'GNU', '9.3.0' ],
  e21 => [ 'gcc', 'g++', 'GNU', '10.1.0', '20', 'gfortran', 'GNU', '10.1.0' ],
  e22 => [ 'gcc', 'g++', 'GNU', '11.1.0', '17', 'gfortran', 'GNU', '11.1.0' ],
  c1  => ['clang', 'clang++', 'Clang', '5.0.0', '17', 'gfortran', 'GNU',
          '7.2.0'
        ],
  c2 => [ 'clang', 'clang++', 'Clang', '5.0.1', '17', 'gfortran', 'GNU',
          '6.4.0'
        ],
  c3 => [ 'clang', 'clang++', 'Clang', '5.0.1', '17', 'gfortran', 'GNU',
          '7.3.0'
        ],
  c4 => [ 'clang', 'clang++', 'Clang', '6.0.0', '17', 'gfortran', 'GNU',
          '6.4.0'
        ],
  c5 => [ 'clang', 'clang++', 'Clang', '6.0.1', '17', 'gfortran', 'GNU',
          '8.2.0'
        ],
  c6 => [ 'clang', 'clang++',  'Clang', '7.0.0-rc3',
          '17',    'gfortran', 'GNU',   '8.2.0'
        ],
  c7 => [ 'clang', 'clang++', 'Clang', '7.0.0', '17', 'gfortran', 'GNU',
          '8.2.0'
        ],
  c8 => [ 'clang', 'clang++',  'Clang', '10.0.0',
          '20',    'gfortran', 'GNU',   '10.1.0'
        ],
  c9 => [ 'clang', 'clang++',  'Clang', '12.0.0',
          '17',    'gfortran', 'GNU',   '11.1.0'
        ],
};

########################################################################
# Private functions
########################################################################


sub _cmake_cetb_compat_defs {
  return [
    map {
      my ($dirkey)   = ($_);
      my $var_stem   = var_stem_for_dirkey($dirkey);
      my $dirkey_ish = $dirkey;
      $dirkey_ish =~ s&([^_])dir\z&${1}_dir&msx;
      "-DCETB_COMPAT_${dirkey_ish}:STRING=${var_stem}";
    } sort keys %{$PATHSPEC_INFO} ];
} ## end sub _cmake_cetb_compat_defs


sub _cmake_defs_for_ups_config {
  my ($pi, $pv_prefix) = @_;
  my @cmake_args = ();
  $pi->{name} and
    push @cmake_args, "-D${pv_prefix}_UPS_PRODUCT_NAME:STRING=$pi->{name}";
  $pi->{version} and
    push @cmake_args,
    "-D${pv_prefix}_UPS_PRODUCT_VERSION:STRING=$pi->{version}";
  $pi->{qualspec} and
    push @cmake_args,
    "-D${pv_prefix}_UPS_QUALIFIER_STRING:STRING=$pi->{qualspec}";
  push @cmake_args, "-D${pv_prefix}_UPS_PRODUCT_FLAVOR:STRING=$pi->{flavor}";
  $pi->{build_only_deps} and push @cmake_args,
    sprintf("-D${pv_prefix}_UPS_BUILD_ONLY_DEPENDENCIES=%s",
            join(q(;), @{ $pi->{build_only_deps} }));
  $pi->{use_time_deps} and push @cmake_args,
    sprintf("-D${pv_prefix}_UPS_USE_TIME_DEPENDENCIES=%s",
            join(q(;), @{ $pi->{use_time_deps} }));
  $pi->{chains} and push @cmake_args,
    sprintf("-D${pv_prefix}_UPS_PRODUCT_CHAINS=%s",
            join(q(;), (sort @{ $pi->{chains} })));
  $pi->{build_only_deps} and List::MoreUtils::any { $_ eq 'cetbuildtools' }
  @{ $pi->{build_only_deps} } and
    push @cmake_args, @{ _cmake_cetb_compat_defs() };
  return @cmake_args;
} ## end sub _cmake_defs_for_ups_config


sub _cmake_project_var_for_pathspec {
  my ($pi, $dirkey) = @_;
  my $pathspec = get_pathspec($pi, $dirkey);
  $pathspec and $pathspec->{key} or return ();
  my $var_stem = $pathspec->{var_stem} || var_stem_for_dirkey($dirkey);
  $pathspec->{var_stem} = $var_stem;
  my $pv_prefix = "CET_PV_$pi->{project_variable_prefix}";
  exists $pathspec->{path} or return ("-D${pv_prefix}_${var_stem}=");
  my @result_elements = ();

  if (ref $pathspec->{key}) { # PATH-like.
    foreach my $pskey (@{ $pathspec->{key} }) {
      pathkey_is_valid($pskey) or
        error_exit("unrecognized pathkey $pskey for $dirkey");
      my $path = shift @{ $pathspec->{path} };
      if ($pskey eq q(-)) {
        $path or last;
        $path =~ m&\A/&msx
          or
          error_exit("non-empty path $path must be absolute",
                     "with pathkey \`$pskey' for directory key $dirkey");
      } elsif ($pskey eq 'fq_dir' and
               $pi->{fq_dir} and
               not $path =~ m&\A/&msx) {

        # Prepend EXEC_PREFIX here to avoid confusion with defaults in CMake.
        $path = File::Spec->catfile($pi->{fq_dir}, $path);
      } elsif ($path =~ m&\A/&msx) {
        warning("redundant pathkey $pskey ignored for absolute path $path",
            "specified for directory key $dirkey: use '-' as a placeholder.");
      }
      push @result_elements, $path;
    } ## end foreach my $pskey (@{ $pathspec...})
    $pathspec->{fq_path} = [@result_elements];
  } else {

    # Single non-elided value.
    push @result_elements, $pathspec->{path};
  }
  return (scalar @result_elements != 1 or $result_elements[0]) ?
    sprintf("-D${pv_prefix}_${var_stem}=%s", join(q(;), @result_elements)) :
    undef;
} ## end sub _cmake_project_var_for_pathspec


sub _fq_path_for {
  my ($pi, $dirkey, $default) = @_;
  my $pathspec =
    get_pathspec($pi, $dirkey) || { key => q(-), path => $default };
  my $fq_path = $pathspec->{fq_path} // q();
  if (not($fq_path or ($pathspec->{key} eq q(-) and not $pathspec->{path}))) {
    my $want_fq = $pi->{fq_dir} && (
                   $pathspec->{key} eq 'fq_dir' or
                   ($pathspec->{key} eq q(-) and
                    List::MoreUtils::any { $_ eq $dirkey } qw(bindir libdir))
    );
    $fq_path = File::Spec->catfile($want_fq ? $pi->{fq_dir} : (),
                                   $pathspec->{path} || $default || ());
  }
  return $fq_path;
} ## end sub _fq_path_for


sub _get_info_from_project_call {
  my ($call_infos, $call_info, $cmakelists, $options) = @_;
  my $qw_saver = # RAII for Perl.
    Cetmodules::Util::VariableSaver->new(\$Cetmodules::QUIET_WARNINGS,
                                         $options->{quiet_warnings} ? 1 : 0);
  $_seen_cet_cmake_env and warning(<<"EOF")
Ignoring project() call at line $call_info->{start_line} following previous call to cet_cmake_env() at line $_seen_cet_cmake_env
EOF
    and return;
  $_seen_project and info(<<"EOF")
Ignoring superfluous project() call at line $call_info->{start_line} following previous call on line $_seen_project
EOF
    and return;
  $_seen_project = $call_info->{start_line};
  my ($project_name, $is_literal) = interpolated($call_info, 0);
  $project_name or error_exit(<<"EOF");
unable to find name in project() call at $cmakelists:$call_info->{start_line}
EOF
  $is_literal or do {
    warning(<<"EOF");
unable to interpret $project_name as a literal CMake project name in $call_info->{name}() at $cmakelists:$call_info->{chunk_locations}->{$call_info->{arg_indexes}->[0]}
EOF
    return;
  };
  my $result = { cmake_project_name => $project_name };
  my $version_idx =
    find_single_value_for($call_info, 'VERSION', @PROJECT_KEYWORDS)
    // return $result;

  # We have a VERSION keyword and value.
  my $version;
  ($version, $is_literal) = interpolated($call_info, $version_idx);
  $is_literal or do {
    my $version_arg_location = arg_location($call_info, $version_idx);
    warning(<<"EOF");
nonliteral version "$version" found at $cmakelists:$version_arg_location
EOF
    return $result;
  };
  @{$result}{qw(cmake_project_version cmake_project_version_info)} =
    ($version, parse_version_string($version));
  return $result;
} ## end sub _get_info_from_project_call


sub _get_info_from_set_calls {
  my ($call_infos, $call_info, $cmakelists, $options) = @_;
  my $qw_saver = # RAII for Perl.
    Cetmodules::Util::VariableSaver->new(\$Cetmodules::QUIET_WARNINGS,
                                         $options->{quiet_warnings} ? 1 : 0);
  my $wanted_pvar = 'CMAKE_PROJECT_VERSION_STRING';
  my ($found_pvar) =
    (interpolated($call_info, 0) // return) =~ m&_(\Q$wanted_pvar\E)\z&msx or
    return;
  $_seen_cet_cmake_env and do {
    warning(<<"EOF");
$call_info->{name}() ignored at line $call_info->{start_line} due to previous call to cet_cmake_env() at line $_seen_cet_cmake_env
EOF
    return;
  };
  my $value;
  my @results = ();
  my $arg_idx = 1;
  while (defined($value = interpolated($call_info, $arg_idx++)) and
         $value ne 'CACHE') {
    push @results, $value;
  }
  return { $found_pvar => @results };
} ## end sub _get_info_from_set_calls


sub _set_seen_cet_cmake_env {
  my ($call_infos, $call_info, $cmakelists, $options) = @_;
  my $call_line = $call_info->{start_line};
  my $qw_saver = # RAII for Perl.
    Cetmodules::Util::VariableSaver->new(\$Cetmodules::QUIET_WARNINGS,
                                         $options->{quiet_warnings} ? 1 : 0);
  $_seen_project or error_exit(<<"EOF");
$call_info->{name}() call at line $call_line MUST follow a project() call"
EOF
  $_seen_cet_cmake_env and error_exit(<<"EOF");
prohibited call to $call_info->{name}() at line $call_line after previous call at line $_seen_cet_cmake_env
EOF
  $_seen_cet_cmake_env = $call_line;
  return;
} ## end sub _set_seen_cet_cmake_env


sub _set_version {
  my ($pi, $cpi, $sourcedir) = @_;
  if ($cpi->{CMAKE_PROJECT_VERSION_STRING}) {
    my $cmake_version_info =
      parse_version_string($cpi->{CMAKE_PROJECT_VERSION_STRING});
    ($pi->{version} // q()) ne q() and
      $pi->{version} ne to_ups_version($cmake_version_info) and
      warning(<<"EOF");
UPS product $pi->{name} version $pi->{version} from product_deps overridden by project variable $cpi->{CMAKE_PROJECT_VERSION_STRING} from $sourcedir/CMakeLists.txt
EOF
    $pi->{version}               = to_ups_version($cmake_version_info);
    $pi->{cmake_project_version} = to_version_string($cmake_version_info);
  } elsif ($cpi->{cmake_project_version_info}) {
    ($pi->{version} // q()) ne q() and
      to_cmake_version($pi->{version}) ne $cpi->{cmake_project_version} and
      warning(<<"EOF");
UPS product $pi->{name} version $pi->{version} from product_deps overridden by VERSION $cpi->{cmake_project_version} from project() in $sourcedir/CMakeLists.txt
EOF
    $pi->{version} = to_ups_version($cpi->{cmake_project_version_info});
  } elsif ($pi->{version}) {
    my $version_info = parse_version_string($pi->{version});
    if ($version_info->{extra}) {
      $pi->{cmake_project_version} = to_version_string($version_info);
    }
  } else {
    warning(<<"EOF");
could not identify a product/project version from product_deps or $sourcedir/CMakeLists.txt.
Ensure version is set in product_deps or with project() or CMAKE_PROJECT_VERSION_STRING project variable in CMakeLists.txt
EOF
  }
  return;
} ## end sub _set_version


sub _setup_err {
  my ($out, @msg_lines) = @_;
  $out->print('test "$?" != 0 && \\', "\n");
  for (@msg_lines) {
    chomp;
    $out->print("  echo \QERROR: $_\E && \\\n");
  }
  $out->print("  return 1 || true\n");
  return;
} ## end sub _setup_err


sub _setup_from_libdir {
  my ($pi, $out, $libdir) = @_;

  # (DY)LD_LIBRARY_PATH.
  $out->print(
      print_dev_setup_var(sprintf("%sLD_LIBRARY_PATH",
                            ($pi->{flavor} =~ m&\bDarwin\b&msx) ? "DY" : q()),
                          File::Spec->catfile('${CETPKG_BUILD}', $libdir)));

  # CET_PLUGIN_PATH. We only want to add to this if it's already set
  # or we're cetlib, which is the package that makes use of it.
  my ($head, @output) =
    split(/\n/msx,
          print_dev_setup_var("CET_PLUGIN_PATH",
                              File::Spec->catfile('${CETPKG_BUILD}', $libdir))
         );
  $out->print("$head\n",
              ($pi->{name} ne 'cetlib') ?
                "test -z \"\${CET_PLUGIN_PATH}\" || \\\n  " :
                q(),
              join("\n", @output),
              "\n");
  return;
} ## end sub _setup_from_libdir

1;