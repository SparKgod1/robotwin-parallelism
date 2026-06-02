pip uninstall nvidia_curobo -y
pip cache purge
cd /workspace/curobo-0.7.8/
rm -rf build/ dist/ curobo.egg-info/ src/curobo.egg-info/

rm -rf /usr/local/cuda-12.1/compat
rm -f /usr/lib/x86_64-linux-gnu/*580.142*
ldconfig
rm -rf ~/.cache/warp

cd /workspace/curobo-0.7.8/
rm -rf build/ dist/ curobo.egg-info/ src/curobo.egg-info/
find src/curobo -name "*.so" -delete
rm -rf ~/.nv/ComputeCache

TORCH_CUDA_ARCH_LIST="8.9+PTX" SETUPTOOLS_SCM_PRETEND_VERSION=0.7.8 pip install -e . --no-build-isolation
pip install warp-lang==1.0.2 -i http://10.200.137.71/mirrors/pypi/simple --trusted-host 10.200.137.71 --default-timeout=1000
CUDA_LAUNCH_BLOCKING=1 TORCH_USE_CUDA_DSA=1 python -c "
import torch
import faulthandler
faulthandler.enable()
from curobo.wrap.reacher.motion_gen import MotionGen, MotionGenConfig
cfg = MotionGenConfig.load_from_robot_config(
  '/mnt/workspace/wfm_data/code/robotwin/assets/embodiments/aloha-agilex/curobo_left.yml',
  None, interpolation_dt=1/250, num_trajopt_seeds=1
)
mg = MotionGen(cfg)
mg.warmup()
print('SUCCESS: CuRobo warmup completed without illegal instructions!')
"

