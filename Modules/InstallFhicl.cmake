#[================================================================[.rst:
X
=
#]================================================================]
########################################################################
# install_fhicl()
#
#   Install fhicl scripts in ${${CETMODULES_CURRENT_PROJECT_NAME}_FHICL_DIR}
#
# Usage: install_fhicl([SUBDIRNAME <subdir>] LIST ...)
#        install_fhicl([SUBDIRNAME <subdir>] [BASENAME_EXCLUDES ...]
#          [EXCLUDES ...] [EXTRAS ...] [SUBDIRS ...])
#
# See CetInstall.cmake for full usage description.
#
# Recognized filename extensions: .fcl
########################################################################

# Avoid unwanted repeat inclusion.
include_guard()

include (CetInstall)
include (ProjectVariable)

function(install_fhicl)
  project_variable(FHICL_DIR "fcl" CONFIG NO_WARN_DUPLICATE
    OMIT_IF_EMPTY OMIT_IF_MISSING OMIT_IF_NULL
    DOCSTRING "Directory below prefix to install FHiCL files")
  if (product AND "$CACHE{${product}_fcldir}" MATCHES "^\\\$") # Resolve placeholder.
    set_property(CACHE ${product}_fcldir PROPERTY VALUE
      "${$CACHE{${product}_fcldir}}")
  endif()
  list(REMOVE_ITEM ARGN PROGRAMS) # Not meaningful.
  if ("LIST" IN_LIST ARGN)
    _cet_install(fhicl ${CETMODULES_CURRENT_PROJECT_NAME}_FHICL_DIR ${ARGN})
  else()
    _cet_install(fhicl ${CETMODULES_CURRENT_PROJECT_NAME}_FHICL_DIR ${ARGN}
      _SQUASH_SUBDIRS _GLOBS "?*.fcl")
  endif()
endfunction()
