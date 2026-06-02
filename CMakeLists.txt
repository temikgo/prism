cmake_minimum_required(VERSION 3.16)
project(prism CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug)
endif()

enable_testing()

add_subdirectory(engine)
add_subdirectory(server)
