<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# uniaudio — Python binding

```bash
nimble clib                                              # build libUniAudio.so
cd py && python3 setup.py build_ext --inplace            # build extension
cd py && python3 -m pytest -q                            # test
```

```python
import uniaudio
uniaudio.version()       # "0.1.0"
uniaudio.fibonacci(10)   # 55
```
