cmake_minimum_required(VERSION 3.16)
project(prism_engine CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug)
endif()

add_library(prism_engine
  src/bot.cpp
  src/card.cpp
  src/game.cpp
  src/protocol.cpp
  src/serialize.cpp
)
target_include_directories(prism_engine PUBLIC include third_party)

# Dev CLI: re-run a recorded replay and print its outcome (deterministic).
add_executable(prism_replay tools/replay.cpp)
target_link_libraries(prism_replay PRIVATE prism_engine)

# Dev CLI: run many bot-vs-bot games and report seat/hero/card winrate skew.
find_package(Threads REQUIRED)
add_executable(prism_selfplay tools/selfplay.cpp)
target_link_libraries(prism_selfplay PRIVATE prism_engine Threads::Threads)

enable_testing()
add_executable(prism_tests tests/tests.cpp)
target_link_libraries(prism_tests PRIVATE prism_engine)
target_compile_definitions(prism_tests PRIVATE
  PRISM_SAMPLE="${CMAKE_CURRENT_SOURCE_DIR}/../cards/sample.json")

include(${CMAKE_CURRENT_SOURCE_DIR}/third_party/doctest.cmake)
doctest_discover_tests(prism_tests)

find_program(CLANG_FORMAT NAMES clang-format)
if(CLANG_FORMAT)
  file(GLOB_RECURSE PRISM_FORMAT_SOURCES CONFIGURE_DEPENDS
    ${CMAKE_CURRENT_SOURCE_DIR}/include/*.hpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/*.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/tools/*.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../server/src/*.hpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../server/src/*.cpp)
  add_test(NAME format_check
    COMMAND ${CLANG_FORMAT} --dry-run --Werror ${PRISM_FORMAT_SOURCES})
endif()
