if (MSVC)
	add_compile_options(
		"$<$<CONFIG:DEBUG>:/W4>"
		"$<$<CONFIG:RELEASE>:/O2>"
	)
else()
	add_compile_options(
		-Wall 
		# -Wpedantic -Wextra -Wstrict-aliasing -Wunreachable-code -Weffc++ -Wno-unused-parameter
		"$<$<CONFIG:DEBUG>:-Og;-ggdb>"
		"$<$<CONFIG:RELWITHDEBINFO>:-O3>"
		"$<$<CONFIG:RELEASE>:-O3>"
	)
endif()


if (CMAKE_SYSTEM_PROCESSOR MATCHES "(amd64)|(AMD64)|(x86_64)")
	option(USE_NATIVE_ARCH "Enable architecture-specific optimizations" OFF)

	if (USE_NATIVE_ARCH)
		if (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
			add_compile_options(/arch:AVX2 /fp:fast)
			message(STATUS "Enabling /arch:AVX2")		 
		else()
			add_compile_options(-march=x86-64-v3)
			message(STATUS "Enabling -march=x86-64-v3")
		endif()
	else()
		set(MULTIFRAME_8X8_CONVOLUTION OFF CACHE BOOL "0" FORCE) 
	endif (USE_NATIVE_ARCH)
endif ()

add_subdirectory(../deps/NeuralAudio NeuralAudio)

set(SOURCES nam_lv2.cpp
	nam_plugin.cpp
	nam_plugin.h)

set(NA_SOURCES ../deps/NeuralAudio/NeuralAudio/NeuralModel.h)

add_library(neural_amp_modeler SHARED ${SOURCES} ${NA_SOURCES})

set(RIG_SOURCES nam_rig_lv2.cpp
	nam_rig_plugin.cpp
	nam_rig_plugin.h
	dynamics.h
	wav_ir.cpp
	wav_ir.h
	oversample.cpp
	oversample.h
	oversample_modes.h
	phase_lanes.h
	rt_worker_pool.cpp
	rt_worker_pool.h)

add_library(neural_amp_modeler_rig SHARED ${RIG_SOURCES} ${NA_SOURCES})

target_include_directories(neural_amp_modeler PUBLIC ../deps/NeuralAudio)
target_include_directories(neural_amp_modeler PUBLIC ../deps/lv2/include)
target_include_directories(neural_amp_modeler PUBLIC ../deps/denormal)

target_link_libraries(neural_amp_modeler PRIVATE NeuralAudio)

target_include_directories(neural_amp_modeler_rig PUBLIC ../deps/NeuralAudio)
target_include_directories(neural_amp_modeler_rig PUBLIC ../deps/lv2/include)
target_include_directories(neural_amp_modeler_rig PUBLIC ../deps/denormal)
target_link_libraries(neural_amp_modeler_rig PRIVATE NeuralAudio)

source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} FILES ${SOURCES})
source_group(NAM ${CMAKE_CURRENT_SOURCE_DIR} FILES ${NA_SOURCES})

option(DISABLE_DENORMALS "Disable floating point denormals" ON)

if (DISABLE_DENORMALS)
	add_definitions(-DDISABLE_DENORMALS)
endif (DISABLE_DENORMALS)

option(SMART_BYPASS_ENABLED "Enable auto-bypass on silence" OFF)

if (SMART_BYPASS_ENABLED)
	add_definitions(-DSMART_BYPASS_ENABLED)
	message(STATUS "Smart Bypass enabled")
else()
	message(STATUS "Smart Bypass NOT enabled")
endif (SMART_BYPASS_ENABLED)

set_target_properties(neural_amp_modeler
	PROPERTIES
	CXX_VISIBILITY_PRESET hidden
	INTERPROCEDURAL_OPTIMIZATION TRUE
	PREFIX ""
	SUFFIX "${CMAKE_SHARED_MODULE_SUFFIX}"
)

set_target_properties(neural_amp_modeler_rig
	PROPERTIES
	CXX_VISIBILITY_PRESET hidden
	INTERPROCEDURAL_OPTIMIZATION TRUE
	PREFIX ""
	SUFFIX "${CMAKE_SHARED_MODULE_SUFFIX}"
)

# Platform

if (CMAKE_SYSTEM_NAME STREQUAL "Windows")
	target_compile_definitions(neural_amp_modeler PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

if (APPLE)
	enable_language(OBJCXX)
	find_library(COCOA_FRAMEWORK Cocoa REQUIRED)
	find_library(AUTHENTICATIONSERVICES_FRAMEWORK AuthenticationServices REQUIRED)
	find_library(SECURITY_FRAMEWORK Security REQUIRED)
	find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)
	find_library(IMAGEIO_FRAMEWORK ImageIO REQUIRED)
	target_link_libraries(neural_amp_modeler_rig PRIVATE ${ACCELERATE_FRAMEWORK})

	add_library(neural_amp_modeler_ui MODULE
		nam_ui.mm
		rig_theme.h rig_theme.mm
		rig_widgets.h rig_widgets.mm)
	target_include_directories(neural_amp_modeler_ui PRIVATE ../deps/lv2/include)
	target_link_libraries(neural_amp_modeler_ui PRIVATE ${COCOA_FRAMEWORK} ${IMAGEIO_FRAMEWORK})
	target_compile_options(neural_amp_modeler_ui PRIVATE -fobjc-arc)
	set_target_properties(neural_amp_modeler_ui PROPERTIES
		PREFIX ""
		SUFFIX "${CMAKE_SHARED_MODULE_SUFFIX}"
	)

	add_library(neural_amp_modeler_rig_ui MODULE
		nam_rig_ui.mm
		rig_theme.h rig_theme.mm
		rig_widgets.h rig_widgets.mm
		rig_knobs.h rig_knobs.cpp
		rig_tone_api.h rig_tone_api.mm
		rig_tone_browser.h rig_tone_browser.mm
		rig_ui_state.h)
	target_include_directories(neural_amp_modeler_rig_ui PRIVATE ../deps/lv2/include)
	target_link_libraries(neural_amp_modeler_rig_ui PRIVATE ${COCOA_FRAMEWORK} ${AUTHENTICATIONSERVICES_FRAMEWORK} ${SECURITY_FRAMEWORK} ${IMAGEIO_FRAMEWORK})
	target_compile_options(neural_amp_modeler_rig_ui PRIVATE -fobjc-arc)
	set_target_properties(neural_amp_modeler_rig_ui PROPERTIES
		PREFIX ""
		SUFFIX "${CMAKE_SHARED_MODULE_SUFFIX}"
	)

	option(BUILD_NAM_STANDALONE "Build the native macOS standalone rig app" OFF)
	if (BUILD_NAM_STANDALONE)
		find_library(COREAUDIO_FRAMEWORK CoreAudio REQUIRED)
		find_library(AUDIOUNIT_FRAMEWORK AudioUnit REQUIRED)
		add_executable(nam_oversampled_rig_standalone MACOSX_BUNDLE
			standalone_main.mm
			nam_rig_plugin.cpp nam_rig_plugin.h
			wav_ir.cpp wav_ir.h
			oversample.cpp oversample.h oversample_modes.h phase_lanes.h
			rt_worker_pool.cpp rt_worker_pool.h
			nam_rig_ui.mm
			rig_theme.h rig_theme.mm
			rig_widgets.h rig_widgets.mm
			rig_knobs.h rig_knobs.cpp
			rig_tone_api.h rig_tone_api.mm
			rig_tone_browser.h rig_tone_browser.mm
			rig_ui_state.h)
		target_include_directories(nam_oversampled_rig_standalone PRIVATE
			../deps/NeuralAudio ../deps/lv2/include ../deps/denormal)
		target_link_libraries(nam_oversampled_rig_standalone PRIVATE NeuralAudio
			${COCOA_FRAMEWORK} ${AUTHENTICATIONSERVICES_FRAMEWORK}
			${SECURITY_FRAMEWORK} ${ACCELERATE_FRAMEWORK} ${IMAGEIO_FRAMEWORK}
			${COREAUDIO_FRAMEWORK} ${AUDIOUNIT_FRAMEWORK})
		target_compile_options(nam_oversampled_rig_standalone PRIVATE -fobjc-arc)
		set_target_properties(nam_oversampled_rig_standalone PROPERTIES
			OUTPUT_NAME "NAM Oversampled Rig"
			MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/resources/standalone-Info.plist.in")
	endif()
endif()
