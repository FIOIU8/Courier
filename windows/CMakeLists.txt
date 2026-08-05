# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(courier_flutter LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "courier_flutter")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
# Flutter creates links from this directory into the Pub cache. Some managed
# Windows environments reject cross-volume link traversal, so resolve link
# targets while configuring without committing machine paths or package versions.
set(_FLUTTER_PLUGINS_FILE "${FLUTTER_MANAGED_DIR}/generated_plugins.cmake")
file(READ "${_FLUTTER_PLUGINS_FILE}" _FLUTTER_PLUGINS_CONTENT)
file(GLOB _FLUTTER_PLUGIN_LINKS LIST_DIRECTORIES true CONFIGURE_DEPENDS
  "${FLUTTER_MANAGED_DIR}/ephemeral/.plugin_symlinks/*")
set(_FLUTTER_PLUGIN_TARGETS "")

foreach(_FLUTTER_PLUGIN_LINK IN LISTS _FLUTTER_PLUGIN_LINKS)
  if(IS_SYMLINK "${_FLUTTER_PLUGIN_LINK}")
    file(READ_SYMLINK "${_FLUTTER_PLUGIN_LINK}" _FLUTTER_PLUGIN_TARGET)
    string(FIND "${_FLUTTER_PLUGIN_TARGET}" ":" _DRIVE_SEPARATOR)
    if(_DRIVE_SEPARATOR GREATER 0)
      math(EXPR _DRIVE_START "${_DRIVE_SEPARATOR} - 1")
      string(SUBSTRING "${_FLUTTER_PLUGIN_TARGET}" ${_DRIVE_START} -1
        _FLUTTER_PLUGIN_TARGET)
    elseif(NOT IS_ABSOLUTE "${_FLUTTER_PLUGIN_TARGET}")
      get_filename_component(_FLUTTER_PLUGIN_LINK_DIR
        "${_FLUTTER_PLUGIN_LINK}" DIRECTORY)
      get_filename_component(_FLUTTER_PLUGIN_TARGET
        "${_FLUTTER_PLUGIN_LINK_DIR}/${_FLUTTER_PLUGIN_TARGET}" ABSOLUTE)
    endif()
    file(TO_CMAKE_PATH "${_FLUTTER_PLUGIN_TARGET}" _FLUTTER_PLUGIN_TARGET)
    if(NOT EXISTS "${_FLUTTER_PLUGIN_TARGET}")
      message(FATAL_ERROR "Flutter plugin target does not exist")
    endif()
    get_filename_component(_FLUTTER_PLUGIN_NAME
      "${_FLUTTER_PLUGIN_LINK}" NAME)
    string(APPEND _FLUTTER_PLUGIN_TARGETS
      "set(_FLUTTER_PLUGIN_TARGET_${_FLUTTER_PLUGIN_NAME} \"${_FLUTTER_PLUGIN_TARGET}\")\n")
  endif()
endforeach()

string(REPLACE
  [=[flutter/ephemeral/.plugin_symlinks/${plugin}]=]
  [=[${_FLUTTER_PLUGIN_TARGET_${plugin}}]=]
  _FLUTTER_PLUGINS_CONTENT
  "${_FLUTTER_PLUGINS_CONTENT}")
string(REPLACE
  [=[flutter/ephemeral/.plugin_symlinks/${ffi_plugin}]=]
  [=[${_FLUTTER_PLUGIN_TARGET_${ffi_plugin}}]=]
  _FLUTTER_PLUGINS_CONTENT
  "${_FLUTTER_PLUGINS_CONTENT}")
string(PREPEND _FLUTTER_PLUGINS_CONTENT "${_FLUTTER_PLUGIN_TARGETS}\n")

set(_RESOLVED_FLUTTER_PLUGINS_FILE
  "${CMAKE_CURRENT_BINARY_DIR}/generated_plugins_resolved.cmake")
file(WRITE "${_RESOLVED_FLUTTER_PLUGINS_FILE}"
  "${_FLUTTER_PLUGINS_CONTENT}")
include("${_RESOLVED_FLUTTER_PLUGINS_FILE}")

# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
