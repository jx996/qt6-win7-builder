cmake_minimum_required(VERSION 3.21)

project(qt6_win7_smoke LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC OFF)

find_package(Qt6 REQUIRED COMPONENTS Core Widgets Network)

if(COMMAND qt_standard_project_setup)
    qt_standard_project_setup()
endif()

qt_add_executable(qt6_win7_smoke
    main.cpp
)

# Network 在链接目标里，main.cpp 的 QSslSocket 才能找到头文件；
# supportsSsl() 顺便验证静态链接进 QtNetwork 的 OpenSSL 真的生效。
target_link_libraries(qt6_win7_smoke PRIVATE Qt6::Core Qt6::Widgets Qt6::Network)
