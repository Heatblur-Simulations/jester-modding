@echo off
setlocal enabledelayedexpansion
rem Combines cassette_*.png screenshots into cassette.mp4.
rem Put this file into the folder with the images and double-click it.
rem Downloads a portable ffmpeg on first run, no installation needed.

cd /d "%~dp0"

rem Seconds each image stays on screen. The screenshots are 3 s apart,
rem so 3 plays back in real time; lower it for a timelapse.
set FRAME_SECONDS=3
set OUTPUT=cassette.mp4
rem 1 = VHS playback look (color fringing, tape grain, washed-out picture),
rem 0 = clean video
set VHS_LOOK=1

rem ---- find or download ffmpeg -------------------------------------------
set FFMPEG=
where ffmpeg >nul 2>nul && set FFMPEG=ffmpeg
if not defined FFMPEG (
    for /r "%~dp0" %%F in (ffmpeg.exe) do if exist "%%F" if not defined FFMPEG set "FFMPEG=%%F"
)
if defined FFMPEG goto encode

echo ffmpeg not found, downloading it (one time, ~100 MB)...
curl -L -o "%~dp0ffmpeg.zip" https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip
if errorlevel 1 (
    echo.
    echo Download failed. Check your internet connection and try again.
    pause
    exit /b 1
)
echo Unpacking...
powershell -NoProfile -Command "Expand-Archive -Force '%~dp0ffmpeg.zip' '%~dp0ffmpeg'"
del "%~dp0ffmpeg.zip"
for /r "%~dp0ffmpeg" %%F in (ffmpeg.exe) do if exist "%%F" if not defined FFMPEG set "FFMPEG=%%F"
if not defined FFMPEG (
    echo.
    echo Could not unpack ffmpeg. Try again or ask the person who sent you this file.
    pause
    exit /b 1
)

:encode
rem ---- build the frame list ----------------------------------------------
set LIST=%TEMP%\cassette_frames.txt
del "%LIST%" 2>nul

set LAST=
for /f "delims=" %%F in ('dir /b /o:n cassette_*.png') do (
    >>"%LIST%" echo file '%%~fF'
    >>"%LIST%" echo duration %FRAME_SECONDS%
    set "LAST=%%~fF"
)
if not defined LAST (
    echo.
    echo No cassette_*.png images found in this folder.
    echo Put this file into the folder with the screenshots and run it again.
    pause
    exit /b 1
)

rem The concat demuxer ignores the duration of the final entry,
rem so the last image is listed once more
>>"%LIST%" echo file '!LAST!'

rem ---- encode --------------------------------------------------------------
rem fps=30 comes first so the VHS grain animates on every frame instead of
rem freezing for the 3 seconds each screenshot is on screen
set "VF=fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p"
if "%VHS_LOOK%"=="1" set "VF=%VF%,chromashift=cbh=4:crh=-4,boxblur=lr=0:cr=2,gblur=sigma=0.4:planes=1,noise=alls=9:allf=t,eq=saturation=0.75:contrast=0.92:brightness=0.02:gamma=1.06,vignette=PI/5"

"%FFMPEG%" -y -f concat -safe 0 -i "%LIST%" ^
    -vf "%VF%" ^
    -c:v libx264 "%OUTPUT%"
set RESULT=%errorlevel%
del "%LIST%"

echo.
if %RESULT%==0 (
    echo Done! The video is saved as %OUTPUT% in this folder.
) else (
    echo Something went wrong, the video was not created.
)
pause
