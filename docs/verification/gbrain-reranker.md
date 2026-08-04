# GBrain local reranker verification

This record captures the local GPU reranker that GBrain can use without rediscovering the runtime, model, endpoint, or request contract.
The evidence below was refreshed on 2026-08-04 on the four-GPU RTX 5060 Ti host.

## Pinned deployment

| Item | Pinned value |
| --- | --- |
| Runtime | llama.cpp `10063`, commit `7d56da7e546f54fb1fa54ef2bc9ad9a872860ab0`, MIT license |
| Runtime package | nixpkgs revision `241313f4e8e508cb9b13278c2b0fa25b9ca27163`, result `/nix/store/pz6pmqda38fp2kx9vnagcmyhfg66chc4-llama-cpp-10063` |
| CUDA | 12.9.86, with `compute_120` reported by `nvcc --list-gpu-arch` |
| Model | `ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF` at repository commit `a02f48bb4f057028298c21fa033da2b30d7742d5` |
| Artifact | `qwen3-reranker-0.6b-q8_0.gguf`, Q8_0, 639153184 bytes, SHA-256 `22c9979ce4fbcdc5acdc310c6641c32797eff1aa980b8f7a2db8a8ea23429a48` |
| Model license | Apache-2.0, as declared by the Hugging Face model card |
| API | `http://127.0.0.1:8081/v1/rerank`, alias `qwen3-reranker-0.6b-q8_0` |
| GPU | `<gpu-uuid>`, PCI `<gpu-pci-address>`, host GPU index `<gpu-index>` |

The artifact source is [ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF](https://huggingface.co/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF).
The serving source is [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp/tree/7d56da7e546f54fb1fa54ef2bc9ad9a872860ab0).

## Runtime selection and build

The llama.cpp `b10252` release had no official Linux CUDA binary, and its official Linux Vulkan binary found no NVIDIA device because this host has no NVIDIA Vulkan ICD manifest.
The deployed runtime therefore uses nixpkgs' maintained CUDA build rather than Ollama's CPU-only bundled server or an ad hoc CMake build.
The pinned nixpkgs expression reproduces the installed result:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix build --impure \
  --out-link "$HOME/.local/share/gbrain-reranker/runtime" \
  --expr 'let
    pkgs = (builtins.getFlake "github:NixOS/nixpkgs/241313f4e8e508cb9b13278c2b0fa25b9ca27163").legacyPackages.x86_64-linux;
  in pkgs.llama-cpp.override { cudaSupport = true; }'
```

The command resolved to the package result recorded above when repeated with `--no-link --print-out-paths`.
The build log reported CUDA compiler `/nix/store/s449s8l8qwi5vikvnvmnrbj2ynyq8597-cuda12.9-cuda_nvcc-12.9.86/bin/nvcc`, CUDA 12.9.86, and GNU 14.3.0 as the CUDA host compiler.
The Nix CUDA setup hook supplied the split toolkit outputs through `CUDAToolkit_ROOT` and `CUDAToolkit_INCLUDE_DIR`, which avoids treating the standalone `cuda_nvcc` output as a conventional complete toolkit.
The resolved discovery inputs were:

```text
CMAKE_CUDA_COMPILER=/nix/store/s449s8l8qwi5vikvnvmnrbj2ynyq8597-cuda12.9-cuda_nvcc-12.9.86/bin/nvcc
CUDAToolkit_ROOT=/nix/store/c5lxrgdwy96hxhy5k5dmr3pdv9ly90id-cuda12.9-libcublas-12.9.1.4-dev;/nix/store/s449s8l8qwi5vikvnvmnrbj2ynyq8597-cuda12.9-cuda_nvcc-12.9.86;/nix/store/cvqcdvcxkn0fwpyzg4nb01zijhab0yll-cuda12.9-libcublas-12.9.1.4-lib;/nix/store/bb623la3ym9xl00d857lzalkx0fv4ng9-cuda12.9-cuda_cccl-12.9.27;/nix/store/zlpxbpka9vgi4p0nlc79irswg3s9vcn3-cuda12.9-libcublas-12.9.1.4-include;/nix/store/hc5s6x4dgirn2dv3kfl6wy5adk9z9sw6-cuda12.9-cuda_cudart-12.9.79
CUDAToolkit_INCLUDE_DIR=/nix/store/s449s8l8qwi5vikvnvmnrbj2ynyq8597-cuda12.9-cuda_nvcc-12.9.86/include;/nix/store/bb623la3ym9xl00d857lzalkx0fv4ng9-cuda12.9-cuda_cccl-12.9.27/include;/nix/store/zlpxbpka9vgi4p0nlc79irswg3s9vcn3-cuda12.9-libcublas-12.9.1.4-include/include;/nix/store/hc5s6x4dgirn2dv3kfl6wy5adk9z9sw6-cuda12.9-cuda_cudart-12.9.79/include
```

The material CUDA and server CMake flags were:

```text
-DCMAKE_BUILD_TYPE=Release
-DLLAMA_BUILD_COMMIT:STRING=7d56da7
-DLLAMA_BUILD_NUMBER:STRING=10063
-DLLAMA_BUILD_EXAMPLES:BOOL=FALSE
-DLLAMA_BUILD_SERVER:BOOL=TRUE
-DLLAMA_BUILD_TESTS:BOOL=FALSE
-DLLAMA_OPENSSL:BOOL=TRUE
-DBUILD_SHARED_LIBS:BOOL=TRUE
-DGGML_BLAS:BOOL=FALSE
-DGGML_CLBLAST:BOOL=FALSE
-DGGML_CUDA:BOOL=TRUE
-DGGML_HIP:BOOL=FALSE
-DGGML_METAL:BOOL=FALSE
-DGGML_RPC:BOOL=FALSE
-DGGML_VULKAN:BOOL=FALSE
-DGGML_CPU_ALL_VARIANTS:BOOL=TRUE
-DGGML_BACKEND_DL:BOOL=TRUE
-DGGML_NATIVE:BOOL=FALSE
-DCMAKE_CUDA_ARCHITECTURES:STRING=75;80;86;89;90;100;103;120;121
-DCMAKE_CUDA_HOST_COMPILER=/nix/store/874na25q9b3br4l8k6gj8qwqv166dr8r-gcc-wrapper-14.3.0/bin/c++
```

llama.cpp normalized architectures `120` and `121` to `120a` and `121a`, then completed all 720 build steps.

## Service contract

The active and enabled user unit is `~/.config/systemd/user/gbrain-reranker.service`.
User lingering is enabled, so `default.target` activation persists across host boots without a system-level unit or sudo.
The unit pins the GPU by UUID with `CUDA_VISIBLE_DEVICES`, loads the CUDA backend explicitly with `GGML_BACKEND_PATH`, and exposes the host driver through a directory containing only a `libcuda.so.1` symlink.
The server is launched with `--reranking --offline --no-webui --host 127.0.0.1 --port 8081 --ctx-size 4096 --batch-size 4096 --ubatch-size 4096 --parallel 1 --n-gpu-layers 999`.
The service uses `Restart=on-failure`, a two-second restart delay, a startup HTTP health probe, journal output, and a 200-message-per-30-second log rate limit.

The current GBrain configuration commands are owned by [`gbrain.md`](../gbrain.md).
The model alias is explicit and does not depend on a serving catalog shorthand.

## Endpoint checks

The startup health probe and an operator check use:

```sh
curl --fail --silent http://127.0.0.1:8081/health
```

The fixed ordering fixture uses:

```sh
curl --fail --silent --show-error http://127.0.0.1:8081/v1/rerank \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3-reranker-0.6b-q8_0",
    "query": "What is the capital city of France?",
    "documents": [
      "Photosynthesis converts light energy into chemical energy in plants.",
      "The Pacific Ocean is the largest ocean on Earth.",
      "Paris is the capital and largest city of France."
    ],
    "top_n": 3
  }'
```

The observed result correctly placed the relevant passage at index 2 first:

```json
{
  "model": "qwen3-reranker-0.6b-q8_0",
  "results": [
    { "index": 2, "relevance_score": 0.995586633682251 },
    { "index": 1, "relevance_score": 0.000018410755728837103 },
    { "index": 0, "relevance_score": 0.000016911413695197552 }
  ]
}
```

The 268-token fixed ordering fixture introduced for story #5 proves the model's ordering behavior only for a short payload.
Because that payload fit the former physical batch size of 512, it did not exercise a representative full archive document and was insufficient to establish the archive retrieval guarantee.
After the service moved to a 4096-token context with physical and micro-batch sizes both set to 4096, a rerank request containing a representative full archive document returned HTTP 200.
The resulting archive-backed GBrain query and MiniMax synthesis evidence are recorded in [`gbrain-init-retrieval.md`](gbrain-init-retrieval.md).
A deliberately oversized input beyond the 4096 service and context bound returned HTTP 500 from llama-server.
For that bounded failure, GBrain records a rerank failure and then returns the non-reranked fallback ranking.
The returned fallback keeps retrieval available, but operators must treat the visible rerank failure as failure rather than evidence of a successful rerank.

## GPU, recovery, and privacy evidence

`nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader` reported:

```text
<gpu-uuid>, <pid>, <home>/.local/share/gbrain-reranker/runtime/bin/llama-server, 1504 MiB
```

The process mappings contained the pinned `libggml-cuda.so`, CUDA driver 570.207, and CUDA 12.9 cuBLAS libraries.
A user-service restart replaced the serving process while the unit remained enabled and the health endpoint returned `{"status":"ok"}`.
Sending `SIGKILL` to the serving process caused systemd to replace it, increment `NRestarts` from 0 to 1, and restore both the health and ordering checks.
After reranking, `ss -anpt` showed only the loopback listener for the serving process and no established remote socket.
The server's `--offline` flag prevents runtime downloads or other network access, and the journal showed model loading from the local GGUF path only.
