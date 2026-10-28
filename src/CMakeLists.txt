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

if (CMAKE_SYSTEM_PROCESSOR MATCHES "(aarch64|arm64)" AND NOT MSVC)
	# AppleClang identifies as "AppleClang", not "Clang", so the check in
	# deps/NeuralAudio/NeuralAudio/CMakeLists.txt never fires on macOS and
	# MULTIFRAME_8X8_CONVOLUTION silently defaults to 0. Inject it from here
	# (before add_subdirectory) so the submodule stays untouched.
	# Override for A/B benchmarking: -DNAM_MULTIFRAME_FORCE=0 (or 8, etc.)
	if (DEFINED NAM_MULTIFRAME_FORCE)
		set(MULTIFRAME_8X8_CONVOLUTION "${NAM_MULTIFRAME_FORCE}" CACHE STRING "Multi-frame 8x8 convolution" FORCE)
		message(STATUS "NAM_MULTIFRAME_FORCE override: MULTIFRAME_8X8_CONVOLUTION=${MULTIFRAME_8X8_CONVOLUTION}")
	else()
		set(MULTIFRAME_8X8_CONVOLUTION "4" CACHE STRING "Multi-frame 8x8 convolution" FORCE)
	endif()
	add_compile_options(-mcpu=native -ffp-contract=fast)
	add_definitions(-DEIGEN_NO_DEBUG)
	message(STATUS "Enabling ARM64 fast path: -mcpu=native, MULTIFRAME_8X8_CONVOLUTION=${MULTIFRAME_8X8_CONVOLUTION}")
endif()

add_subdirectory(../deps/NeuralAudio NeuralAudio)

set(SOURCES nam_lv2.cpp
	nam_plugin.cpp
	nam_plugin.h)

set(NA_SOURCES ../deps/NeuralAudio/NeuralAudio/NeuralModel.h)

add_library(neural_amp_modeler SHARED ${SOURCES} ${NA_SOURCES})

set(RIG_CORE_SOURCES
	cabinet_worker.cpp cabinet_worker.h
	nam_rig_plugin.cpp
	nam_rig_plugin.h
	dsp_accel.cpp dsp_accel.h
	dynamics.h
	wav_ir.cpp
	wav_ir.h
	oversample.cpp
	oversample.h
	oversample_modes.h
	amp_advanced.h
	output_transformer.h
	speaker_dynamics.h
	space_fx.h)

add_library(rig_dsp_core OBJECT ${RIG_CORE_SOURCES} ${NA_SOURCES})
set_target_properties(rig_dsp_core PROPERTIES
	POSITION_INDEPENDENT_CODE ON
	CXX_VISIBILITY_PRESET hidden
)
if (APPLE)
	target_compile_options(rig_dsp_core PRIVATE -mmacosx-version-min=11.0)
endif()
target_include_directories(rig_dsp_core PUBLIC
	${CMAKE_CURRENT_SOURCE_DIR}
	../deps/NeuralAudio
	../deps/lv2/include
	../deps/denormal
	../deps/NeuralAudio/deps/RTNeural/modules/json)

set(RIG_SOURCES nam_rig_lv2.cpp ${RIG_CORE_SOURCES})

add_library(neural_amp_modeler_rig SHARED nam_rig_lv2.cpp $<TARGET_OBJECTS:rig_dsp_core> ${NA_SOURCES})

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

# Offline A/B benchmark (EXCLUDE_FROM_ALL: never ships in the bundle).
# Times model->Process() + True-Nx converters on real .nam files so the
# MULTIFRAME_8X8_CONVOLUTION effect can be A/B'd against converters and
# the sample-count multiplier. Build with:
#   cmake --build <dir> --target nam_bench
# and select the convolution path with -DNAM_MULTIFRAME_FORCE=0/4/8.
add_executable(nam_bench EXCLUDE_FROM_ALL
	../tools/bench_models.cpp
	dsp_accel.cpp
	oversample.cpp
	oversample.h)
target_include_directories(nam_bench PRIVATE
	${CMAKE_CURRENT_SOURCE_DIR}
	${CMAKE_CURRENT_SOURCE_DIR}/../deps/NeuralAudio
	${CMAKE_CURRENT_SOURCE_DIR}/../deps/denormal)
target_link_libraries(nam_bench PRIVATE NeuralAudio)
if (APPLE)
	find_library(NAM_BENCH_ACCELERATE_FRAMEWORK Accelerate REQUIRED)
	target_link_libraries(nam_bench PRIVATE ${NAM_BENCH_ACCELERATE_FRAMEWORK})
endif()

# Polyphase oversampling + NEON WaveNet kernel verification on real models
# (EXCLUDE_FROM_ALL). Build with: cmake --build <dir> --target verify_polyphase_model
add_executable(verify_polyphase_model EXCLUDE_FROM_ALL
	../tests/verify_polyphase_model.cpp)
target_include_directories(verify_polyphase_model PRIVATE
	${CMAKE_CURRENT_SOURCE_DIR}/../deps/NeuralAudio)
target_compile_definitions(verify_polyphase_model PRIVATE
	NAM_REPO_DIR="${CMAKE_CURRENT_SOURCE_DIR}/..")
target_link_libraries(verify_polyphase_model PRIVATE NeuralAudio)

add_executable(verify_control_work EXCLUDE_FROM_ALL ../tests/verify_control_work.cpp)
target_include_directories(verify_control_work PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

add_executable(verify_rig_dsp_cache EXCLUDE_FROM_ALL ../tests/verify_rig_dsp_cache.cpp)
target_include_directories(verify_rig_dsp_cache PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

find_package(Threads REQUIRED)
add_executable(verify_standalone_worker EXCLUDE_FROM_ALL
	../tests/verify_standalone_worker.cpp standalone_worker.cpp)
target_include_directories(verify_standalone_worker PRIVATE ../deps/lv2/include ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(verify_standalone_worker PRIVATE Threads::Threads)

add_executable(verify_standalone_controls EXCLUDE_FROM_ALL ../tests/verify_standalone_controls.cpp)
target_include_directories(verify_standalone_controls PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
	../deps/lv2/include ../deps/NeuralAudio ../deps/NeuralAudio/deps/RTNeural/modules/json)

add_executable(verify_rig_control_metadata EXCLUDE_FROM_ALL
	../tests/verify_rig_control_metadata.cpp win32_presets.cpp)
target_include_directories(verify_rig_control_metadata PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
	../deps/NeuralAudio/deps/NeuralAmpModelerCore/Dependencies)
if (WIN32)
	target_link_libraries(verify_rig_control_metadata PRIVATE shell32)
endif()

if (NOT APPLE)
	add_library(pffft STATIC
		${CMAKE_CURRENT_SOURCE_DIR}/../deps/pffft/src/pffft.c
		${CMAKE_CURRENT_SOURCE_DIR}/../deps/pffft/src/pffft_common.c
	)
	target_compile_definitions(pffft PUBLIC PFFFT_STATIC_DEFINE)
	target_include_directories(pffft PUBLIC
		${CMAKE_CURRENT_SOURCE_DIR}/../deps/pffft/include
		${CMAKE_CURRENT_SOURCE_DIR}/../deps/pffft/include/pffft
	)
	target_link_libraries(rig_dsp_core PRIVATE pffft)
	target_link_libraries(neural_amp_modeler_rig PRIVATE pffft)
	target_link_libraries(nam_bench PRIVATE pffft)
	target_include_directories(rig_dsp_core PUBLIC
		${CMAKE_CURRENT_SOURCE_DIR}/../deps/pffft/include
		${CMAKE_CURRENT_SOURCE_DIR}/../deps/NeuralAudio/deps/NeuralAmpModelerCore/Dependencies
		${CMAKE_CURRENT_SOURCE_DIR}/../deps/NeuralAudio/deps/RTNeural/modules/json
	)
	target_include_directories(neural_amp_modeler_rig PUBLIC
		${CMAKE_CURRENT_SOURCE_DIR}/../deps/pffft/include
		${CMAKE_CURRENT_SOURCE_DIR}/../deps/NeuralAudio/deps/NeuralAmpModelerCore/Dependencies
		${CMAKE_CURRENT_SOURCE_DIR}/../deps/NeuralAudio/deps/RTNeural/modules/json
	)
endif()

# Platform

if (WIN32)
	target_compile_definitions(neural_amp_modeler PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
	target_compile_definitions(rig_dsp_core PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN PFFFT_STATIC_DEFINE)
	target_compile_definitions(neural_amp_modeler_rig PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN PFFFT_STATIC_DEFINE)
	target_link_libraries(neural_amp_modeler_rig PRIVATE winmm avrt ole32)

	add_library(neural_amp_modeler_rig_ui MODULE
		nam_rig_win32_ui.cpp
		win32_ui_view.h win32_ui_view.cpp
		win32_presets.h win32_presets.cpp
	)
	target_compile_definitions(neural_amp_modeler_rig_ui PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN PFFFT_STATIC_DEFINE)
	target_include_directories(neural_amp_modeler_rig_ui PRIVATE
		${CMAKE_CURRENT_SOURCE_DIR}
		../deps/lv2/include
		../deps/NeuralAudio
		../deps/NeuralAudio/deps/NeuralAmpModelerCore/Dependencies
		../deps/NeuralAudio/deps/RTNeural/modules/json
	)
	target_link_libraries(neural_amp_modeler_rig_ui PRIVATE
		gdiplus gdi32 comctl32 comdlg32 shell32 ole32 oleaut32 uuid shlwapi
	)
	set_target_properties(neural_amp_modeler_rig_ui PROPERTIES
		PREFIX ""
		SUFFIX "${CMAKE_SHARED_MODULE_SUFFIX}"
	)

	option(BUILD_AXE_FX_STANDALONE "Build Axe FX standalone host application" ON)
	if (BUILD_AXE_FX_STANDALONE)
		add_executable(axe_fx_standalone WIN32
			standalone_main_win32.cpp
			standalone_worker.cpp standalone_worker.h standalone_controls.h
			win32_audio.h win32_audio.cpp
			win32_asio.h
			win32_ui_view.h win32_ui_view.cpp
			win32_presets.h win32_presets.cpp
			$<TARGET_OBJECTS:rig_dsp_core>
		)
		target_compile_definitions(axe_fx_standalone PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN PFFFT_STATIC_DEFINE)
		target_include_directories(axe_fx_standalone PRIVATE
			${CMAKE_CURRENT_SOURCE_DIR}
			../deps/NeuralAudio
			../deps/lv2/include
			../deps/denormal
			../deps/pffft/include
			../deps/NeuralAudio/deps/NeuralAmpModelerCore/Dependencies
			../deps/NeuralAudio/deps/RTNeural/modules/json
		)
		target_link_libraries(axe_fx_standalone PRIVATE
			NeuralAudio pffft Threads::Threads
			gdiplus gdi32 comctl32 comdlg32 shell32 ole32 oleaut32 uuid shlwapi winmm avrt
		)
		set_target_properties(axe_fx_standalone PROPERTIES
			OUTPUT_NAME "Axe FX"
		)
	endif()
endif()

if (APPLE)
	enable_language(OBJCXX)
	find_library(COCOA_FRAMEWORK Cocoa REQUIRED)
	find_library(AUTHENTICATIONSERVICES_FRAMEWORK AuthenticationServices REQUIRED)
	find_library(SECURITY_FRAMEWORK Security REQUIRED)
	find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)
	find_library(IMAGEIO_FRAMEWORK ImageIO REQUIRED)
	find_library(QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)
	find_library(COREIMAGE_FRAMEWORK CoreImage REQUIRED)
	find_library(AUDIOTOOLBOX_FRAMEWORK AudioToolbox REQUIRED)
	target_link_libraries(neural_amp_modeler_rig PRIVATE ${ACCELERATE_FRAMEWORK})
	add_executable(verify_riff_recorder EXCLUDE_FROM_ALL
		../tests/verify_riff_recorder.mm rig_riff_recorder.mm)
	target_include_directories(verify_riff_recorder PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
	target_link_libraries(verify_riff_recorder PRIVATE ${COCOA_FRAMEWORK} ${AUDIOTOOLBOX_FRAMEWORK})
	target_compile_options(verify_riff_recorder PRIVATE -fobjc-arc -UNDEBUG)
	add_executable(verify_riff_renderer EXCLUDE_FROM_ALL ../tests/verify_riff_renderer.mm
		rig_riff_renderer.mm $<TARGET_OBJECTS:rig_dsp_core>)
	target_include_directories(verify_riff_renderer PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
		../deps/NeuralAudio ../deps/lv2/include ../deps/denormal)
	target_compile_options(verify_riff_renderer PRIVATE -fobjc-arc -UNDEBUG -Wno-incomplete-implementation)
	target_link_libraries(verify_riff_renderer PRIVATE NeuralAudio ${COCOA_FRAMEWORK} ${ACCELERATE_FRAMEWORK})
	add_executable(verify_local_match_engine EXCLUDE_FROM_ALL
		../tests/verify_local_tone_matcher.mm rig_local_tone_matcher.mm rig_ai_support.mm
		rig_riff_renderer.mm $<TARGET_OBJECTS:rig_dsp_core>)
	target_compile_definitions(verify_local_match_engine PRIVATE NAMRIG_REAL_RENDER)
	target_include_directories(verify_local_match_engine PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
		../deps/NeuralAudio ../deps/lv2/include ../deps/denormal)
	target_compile_options(verify_local_match_engine PRIVATE -fobjc-arc -UNDEBUG -Wno-incomplete-implementation)
	target_link_libraries(verify_local_match_engine PRIVATE NeuralAudio ${COCOA_FRAMEWORK} ${ACCELERATE_FRAMEWORK})
	add_executable(verify_low_buffer_rig EXCLUDE_FROM_ALL ../tests/verify_low_buffer_rig.cpp)
	target_include_directories(verify_low_buffer_rig PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
		../deps/lv2/include ../deps/NeuralAudio ../deps/NeuralAudio/deps/RTNeural/modules/json)
	add_executable(verify_cabinet_worker EXCLUDE_FROM_ALL
		../tests/verify_cabinet_worker.cpp cabinet_worker.cpp)
	target_include_directories(verify_cabinet_worker PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
	add_executable(verify_parallel_polyphase EXCLUDE_FROM_ALL
		../tests/verify_parallel_polyphase.cpp polyphase_worker.h cabinet_worker.cpp)
	target_include_directories(verify_parallel_polyphase PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
		../deps/NeuralAudio)
	target_compile_definitions(verify_parallel_polyphase PRIVATE
		NAM_REPO_DIR="${CMAKE_CURRENT_SOURCE_DIR}/.."
		NAMRIG_VERIFY_POLYPHASE_POLICY_FAILURE
		thread_policy_set=verifyPolyphasePolicySet)
	target_link_libraries(verify_parallel_polyphase PRIVATE
		NeuralAudio Threads::Threads ${ACCELERATE_FRAMEWORK})
	add_executable(verify_parallel_cabs EXCLUDE_FROM_ALL
		../tests/verify_parallel_cabs.cpp $<TARGET_OBJECTS:rig_dsp_core>)
	target_include_directories(verify_parallel_cabs PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
		../deps/NeuralAudio ../deps/lv2/include ../deps/denormal)
	target_link_libraries(verify_parallel_cabs PRIVATE NeuralAudio ${ACCELERATE_FRAMEWORK})

	add_library(neural_amp_modeler_ui MODULE
		nam_ui.mm
		rig_theme.h rig_theme.mm
		rig_widgets.h rig_widgets.mm)
	target_include_directories(neural_amp_modeler_ui PRIVATE ../deps/lv2/include)
	target_link_libraries(neural_amp_modeler_ui PRIVATE ${COCOA_FRAMEWORK} ${IMAGEIO_FRAMEWORK} ${QUARTZCORE_FRAMEWORK})
	target_compile_options(neural_amp_modeler_ui PRIVATE -fobjc-arc)
	set_target_properties(neural_amp_modeler_ui PROPERTIES
		PREFIX ""
		SUFFIX "${CMAKE_SHARED_MODULE_SUFFIX}"
	)

	set(RIG_UI_SOURCES
		nam_rig_ui.mm
		rig_theme.h rig_theme.mm
		rig_widgets.h rig_widgets.mm
		rig_knobs.h rig_knobs.cpp
		rig_presets.h rig_presets.mm
		rig_profile_catalog.h rig_profile_catalog.mm
		rig_tone_api.h rig_tone_api.mm
		rig_tone_browser.h rig_tone_browser.mm
		rig_ai_copilot.h rig_ai_copilot.mm
		rig_ai_support.h rig_ai_support.mm
		rig_ai_model_catalog.h rig_ai_model_catalog.mm
		rig_local_server.h rig_local_server.mm
		rig_riff_recorder.h rig_riff_recorder.mm
		rig_local_tone_matcher.h rig_local_tone_matcher.mm local_tone_learning.h
		rig_ui_state.h)
	add_library(rig_ui_core OBJECT ${RIG_UI_SOURCES})
	set_target_properties(rig_ui_core PROPERTIES POSITION_INDEPENDENT_CODE ON)
	target_include_directories(rig_ui_core PRIVATE
		../deps/NeuralAudio ../deps/lv2/include ../deps/denormal
		../deps/NeuralAudio/deps/RTNeural/modules/json)
	target_compile_options(rig_ui_core PRIVATE -fobjc-arc -mmacosx-version-min=11.0)

	# The local tone matcher screens cab IRs offline (WavIR taps + FFT convolution).
	add_library(neural_amp_modeler_rig_ui MODULE $<TARGET_OBJECTS:rig_ui_core> dsp_accel.cpp wav_ir.cpp)
	target_include_directories(neural_amp_modeler_rig_ui PRIVATE ../deps/lv2/include)
	target_link_libraries(neural_amp_modeler_rig_ui PRIVATE ${COCOA_FRAMEWORK} ${AUTHENTICATIONSERVICES_FRAMEWORK} ${SECURITY_FRAMEWORK} ${IMAGEIO_FRAMEWORK} ${QUARTZCORE_FRAMEWORK} ${COREIMAGE_FRAMEWORK} ${AUDIOTOOLBOX_FRAMEWORK} ${ACCELERATE_FRAMEWORK})
	target_compile_options(neural_amp_modeler_rig_ui PRIVATE -fobjc-arc)
	set_target_properties(neural_amp_modeler_rig_ui PROPERTIES
		PREFIX ""
		SUFFIX "${CMAKE_SHARED_MODULE_SUFFIX}"
	)

	option(BUILD_AXE_FX_STANDALONE "Build the native macOS Axe FX app" ON)
	if (BUILD_AXE_FX_STANDALONE)
		option(AXE_FX_PARALLEL_MODELS_DEFAULT "Enable macOS parallel model phases by default" ON)
		option(AXE_FX_PARALLEL_CABS_DEFAULT "Enable macOS threaded NAM cabinets by default" OFF)
		find_library(COREAUDIO_FRAMEWORK CoreAudio REQUIRED)
		find_library(AUDIOUNIT_FRAMEWORK AudioUnit REQUIRED)
		add_executable(axe_fx_standalone MACOSX_BUNDLE
			standalone_main.mm
			rig_riff_renderer.h rig_riff_renderer.mm
			standalone_worker.cpp standalone_worker.h standalone_controls.h
			rig_standalone_profiler.h rig_standalone_profiler.mm
			$<TARGET_OBJECTS:rig_dsp_core>
			$<TARGET_OBJECTS:rig_ui_core>
			${CMAKE_SOURCE_DIR}/resources/AxeFX.icns
			${CMAKE_SOURCE_DIR}/resources/AxeFX.png)
		set_source_files_properties(
			${CMAKE_SOURCE_DIR}/resources/AxeFX.icns
			${CMAKE_SOURCE_DIR}/resources/AxeFX.png
			PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
		target_include_directories(axe_fx_standalone PRIVATE
			../deps/NeuralAudio ../deps/lv2/include ../deps/denormal
			../deps/NeuralAudio/deps/RTNeural/modules/json)
		target_compile_definitions(axe_fx_standalone PRIVATE
			AXE_FX_PARALLEL_MODELS_DEFAULT=$<BOOL:${AXE_FX_PARALLEL_MODELS_DEFAULT}>
			AXE_FX_PARALLEL_CABS_DEFAULT=$<BOOL:${AXE_FX_PARALLEL_CABS_DEFAULT}>)
		target_link_libraries(axe_fx_standalone PRIVATE NeuralAudio Threads::Threads
			${COCOA_FRAMEWORK} ${AUTHENTICATIONSERVICES_FRAMEWORK}
			${SECURITY_FRAMEWORK} ${ACCELERATE_FRAMEWORK} ${IMAGEIO_FRAMEWORK}
			${QUARTZCORE_FRAMEWORK} ${COREIMAGE_FRAMEWORK}
			${COREAUDIO_FRAMEWORK} ${AUDIOUNIT_FRAMEWORK} ${AUDIOTOOLBOX_FRAMEWORK})
		target_compile_options(axe_fx_standalone PRIVATE -fobjc-arc -mmacosx-version-min=11.0)
		target_link_options(axe_fx_standalone PRIVATE "-Wl,-platform_version,macos,11.0,14.5")
		set_target_properties(axe_fx_standalone PROPERTIES
			OUTPUT_NAME "Axe FX"
			MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/resources/standalone-Info.plist.in")
	endif()
endif()
