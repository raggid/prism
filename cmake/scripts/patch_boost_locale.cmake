# Apply the Boost.Locale CMake 4.5 fix unless the source already has an equivalent change.
# Usage: cmake -DPATCH_EXECUTABLE=<patch> -DPATCH_FILE=<file> -P patch_boost_locale.cmake (run in the Boost source dir)
set(locale_lists "libs/locale/CMakeLists.txt")
file(READ "${locale_lists}" locale_contents)
if(locale_contents MATCHES "REMOVE_ITEM sources_inc[^\n]*locale\\.hpp" OR locale_contents MATCHES "locale\\\\\\.hpp\\$")
    message(STATUS "Boost.Locale already excludes locale.hpp from its header group")
    return()
endif()
execute_process(
        COMMAND "${PATCH_EXECUTABLE}" -p1 --forward -i "${PATCH_FILE}"
        RESULT_VARIABLE patch_result)
if(NOT patch_result EQUAL 0)
    message(FATAL_ERROR "Failed to apply ${PATCH_FILE}")
endif()
