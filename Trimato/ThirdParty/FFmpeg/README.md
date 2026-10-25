# FFmpeg distribution notes

Trimato includes the `ffmpeg` and `ffprobe` command-line programs from FFmpeg 8.1.2. They support media inspection, conversion, effects, and exports alongside AVFoundation.

The bundled programs are universal macOS executables for arm64 and x86_64. Matching universal dSYM bundles are retained in `Symbols` and copied into every Xcode archive so FFmpeg and FFprobe crashes can be symbolicated. The build fails if an executable and its dSYM do not contain the same architecture UUIDs. The tools are compiled without `--enable-gpl` and without `--enable-nonfree`. No external GPL codec libraries are linked. H.264 output uses Apple's VideoToolbox framework and AAC output uses FFmpeg's native AAC encoder. If VideoToolbox reports that H.264 encoding is temporarily unavailable, Trimato retries with FFmpeg's LGPL MPEG-4 Part 2 encoder in the same MP4 container rather than failing the user's export.

Trimato's FFmpeg build is restricted to local media. FFmpeg networking, HLS input and output, and all general-purpose protocols are disabled. Only the `file`, `pipe`, and `fd` protocols are enabled for local files, progress reporting, and local file descriptors. The bundled tools cannot open HTTP, FTP, RTMP, RTP, SRTP, TCP, UDP, encrypted HLS, or FFmpeg `crypto` protocol sources.

FFmpeg is licensed under the GNU Lesser General Public License version 2.1 or later. The license text is included in `COPYING.LGPLv2.1`. Corresponding source is available from https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz and can be rebuilt with `build-ffmpeg.sh` in this directory.

The exact configure flags reported by the bundled binary are recorded in `build-configuration.txt` after each release build. Patent licensing requirements for H.264 and AAC are separate from FFmpeg's copyright license and must be evaluated before distribution.

The source archive, extracted source, and intermediate build directories are intentionally excluded from version control. Only the redistributable tools, matching dSYMs, license, build script, and recorded configuration belong in the app repository.

## Optimized builds

Install NASM or set `NASM` to its executable path before running `build-ffmpeg.sh`. The Intel slice uses FFmpeg's assembly routines and runtime CPU detection; the Apple silicon slice uses its native ARM optimizations. The script cross-compiles the other architecture without running its executables. Rosetta is not required for building. Execution tests on Intel still require an Intel Mac or an available Intel execution environment.

For an incremental rebuild, `FFMPEG_BUILD_ARCHITECTURES=x86_64` rebuilds only the Intel slice before combining both existing slices. A fresh build should use the default, which builds both architectures.
