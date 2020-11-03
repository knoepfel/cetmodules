########################################################################
# CetFindPackage.cmake
#
#   Wrapper around CMake's find_package function to track transitive
#   dependencies for dependents.
#
####################################
# cet_find_package(<find_package-args>...
#                  [[PUBLIC] [PRIVATE]|INTERFACE]
#                  [REQUIRED_BY <components>...])
#
#   External dependencies specified using cet_find_package() will be
#   automatically collated and added to ${PROJECT_NAME}Config.cmake as
#   approriate (see OPTIONS).
#
# ################
# OPTIONS
#
#   BUILD_ONLY
#
#     Synonym for PRIVATE (see below).
#
#   INTERFACE
#   PUBLIC
#   PRIVATE
#
#     These options match the eponymous options to CMake's
#     target_link_libraries() and other functions. If INTERFACE or
#     PUBLIC is specified, an appropriate find_dependency() call will be
#     added to this package's Config.cmake file to ensure that the
#     required package will be found when necessary for dependent
#     packages. Default to PUBLIC if none are specified.
#
#   REQUIRED_BY <components>
#
#     If this dependency is not universally required by all the
#     components your package provides, this option will ensure that it
#     will only be loaded when a dependent package requests the relevant
#     component(s).
#
# ################
# NOTES
#
# * Minimize unwanted dependencies downstream by using PUBLIC, INTERFACE
#   and PRIVATE as necessary to match their use in cet_make(),
#   cet_make_library(), cet_make_exec() and their CMake equivalents,
#   add_library() and add_executable().
#
# * cet_find_package() will NOT execute CMake directives with global
#   effect such as include_directories(). Use target_link_libraries()
#   instead with target (package::lib_name) rather than variable
#   (PACKAGE_...) to ensure that all PUBLIC headers associated with a
#   library will be found.
#
# * Works best when combined with appropriate use of PUBLIC, INTERFACE
#   and PRIVATE (or BUILD_ONLY) with cet_make_library() - or
#   alternatively, target_link_libraries() and
#   target_include_directories() - minimizing unwanted transitive
#   dependencies downstream.
#
# * Multiple find_package() directives (perhaps with different
#   requirement levels or component settings) will be propagated for
#   execution in the order they were encountered. find_package() will
#   minimize duplication of effort internally.
########################################################################

include_guard(DIRECTORY)

cmake_policy(PUSH)
cmake_minimum_required(VERSION 3.18.2 FATAL_ERROR)

macro(cet_find_package)
  cmake_parse_arguments(_CFP "BUILD_ONLY;INTERFACE;PRIVATE;PUBLIC"
    "" "REQUIRED_BY" "${ARGN}")
  if (NOT _CFP_INTERFACE AND NOT _CFP_PRIVATE AND NOT _CFP_BUILD_ONLY AND NOT _CFP_PUBLIC)
    set(_CFP_PUBLIC TRUE)
  endif()
  if (_CFP_PUBLIC OR _CFP_PRIVATE OR _CFP_BUILD_ONLY)
    find_package(${_CFP_UNPARSED_ARGUMENTS})
  endif()
  if (_CFP_INTERFACE OR _CFP_PUBLIC)
    # Register all arguments used for each component requiring this
    # dependency:
    if (_CFP_REQUIRED_BY)
      foreach (component IN LISTS _CFP_REQUIRED_BY)
        _add_transitive_dependency(COMPONENT ${component}
          "${_CFP_UNPARSED_ARGUMENTS}")
      endforeach()
    else()
      _add_transitive_dependency("${_CFP_UNPARSED_ARGUMENTS}")
    endif()
  endif()
endmacro()

# Add an find_dependency() call to the appropriate tracking variable.
function(_add_transitive_dependency FIRST_ARG)
  # Deal with optional leading COMPONENT <component> ourselves, as with
  # cmake_parse_arguments() we'd have to worry about what we might have
  # passed to find_package().
  if (FIRST_ARG STREQUAL "COMPONENT")
    list(POP_FRONT ARGN COMPONENT DEP)
    set(cache_var
      CETMODULES_FIND_DEPS_COMPONENT_${COMPONENT}_PROJECT_${PROJECT_NAME})
    set(docstring_extra " component ${COMPONENT}")
  else()
    set(DEP "${FIRST_ARG}")
    set(cache_var CETMODULES_FIND_DEPS_PROJECT_${PROJECT_NAME})
    unset(docstring_extra)
  endif()
  # Set up the beginning of the call.
  set(find_dep_string "find_dependency(")
  string(LENGTH "${find_dep_string}" cursor)
  set(indent 4)
  string(REPEAT " " ${indent} fill)
  # Add each arg in turn, keeping line length below 72 if possible.
  foreach (arg IN LISTS DEP ARGN)
    string(LENGTH "${arg}" arglen)
    math(EXPR new_cursor "${cursor} + ${arglen} + 1")
    if (new_cursor LESS_EQUAL 72)
      set(cursor ${new_cursor})
    else()
      # Strip trailing whitespace and start a new indented line.
      string(REGEX REPLACE " +$" ""
        find_dep_string "${find_dep_string}")
      list(APPEND ${cache_var} "${find_dep_string}")
      set(find_dep_string "${fill}")
      math(EXPR cursor "${indent} + ${arglen} + 1")
    endif()
    # Print an argument with trailing space.
    string(APPEND find_dep_string "${arg} ")
  endforeach()
  # Strip the trailing space before closing the function call.
  string(REGEX REPLACE " +$" ""
    find_dep_string "${find_dep_string}")
  list(APPEND ${cache_var} "${find_dep_string}")
  if (NOT DEFINED CACHE{${cache_var}})
    set(${cache_var} "${${cache_var}})" CACHE INTERNAL
      "Transitive dependency directives for ${PROJECT_NAME}\
${docstring_extra}\
")
  else()
    set_property(CACHE ${cache_var}
      PROPERTY VALUE "${${cache_var}})")
  endif()
endfunction()

cmake_policy(POP)