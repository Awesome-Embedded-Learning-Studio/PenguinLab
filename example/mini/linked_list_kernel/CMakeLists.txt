cmake_minimum_required(VERSION 3.16)
project(penguin_list_test C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)

add_compile_options(-Wall -Wextra -Wpedantic)

add_executable(penguin_example penguin_example.c)
