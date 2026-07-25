cmake_minimum_required(VERSION 3.20)
project(tzrp CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../discord_social_sdk")

add_library(tzrp SHARED src/tzrp.cpp)

target_include_directories(tzrp PRIVATE "${SDK_DIR}/include")
target_link_libraries(tzrp PRIVATE "${SDK_DIR}/lib/release/discord_partner_sdk.lib")

# The game loads this by path out of the mod folder; keep the name stable.
set_target_properties(tzrp PROPERTIES OUTPUT_NAME "tzrp")
