@echo off
REM ================================================================
REM S80 FP16 MAC - Vivado xsim Simulation Script
REM ================================================================

set VIVADO_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL_DIR=..\..\rtl\common
set TB_DIR=..\..\tb\m1
set WORK_DIR=xsim_work

echo ==============================================
echo   S80 FP16 MAC - xsim Simulation
echo ==============================================
echo.

REM Clean previous run
if exist %WORK_DIR% rmdir /s /q %WORK_DIR%
if exist xsim.dir rmdir /s /q xsim.dir
del /q *.log *.jou *.pb *.wdb 2>nul

REM Step 1: Compile SystemVerilog sources
echo [1/3] Compiling RTL + Testbench...
%VIVADO_BIN%\xvlog.bat -sv -d FPGA -L unisims_ver ^
    %RTL_DIR%\s80_pkg.sv ^
    %RTL_DIR%\fp16_unpack.sv ^
    %RTL_DIR%\fp16_pack.sv ^
    %RTL_DIR%\dsp48_mul_wrapper.sv ^
    %RTL_DIR%\fp32_accumulator.sv ^
    %RTL_DIR%\fp32_normalizer.sv ^
    %RTL_DIR%\fp16_mac.sv ^
    %TB_DIR%\tb_fp16_mac.sv
if errorlevel 1 (
    echo ERROR: Compilation failed!
    exit /b 1
)

echo.
echo [2/3] Elaborating...
%VIVADO_BIN%\xelab.bat tb_fp16_mac -timescale 1ns/1ps -debug typical -L unisims_ver -s sim_snapshot
if errorlevel 1 (
    echo ERROR: Elaboration failed!
    exit /b 1
)

echo.
echo [3/3] Running simulation...
%VIVADO_BIN%\xsim.bat sim_snapshot -runall -log sim_results.log
if errorlevel 1 (
    echo ERROR: Simulation failed!
    exit /b 1
)

echo.
echo ==============================================
echo   Simulation Complete - see sim_results.log
echo ==============================================
