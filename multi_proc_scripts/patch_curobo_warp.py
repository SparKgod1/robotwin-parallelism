"""
Monkey-patch curobo to bypass Warp kernels with pure PyTorch implementations.
Import this module before using curobo to avoid Warp-related segfaults.

Usage:
    import patch_curobo_warp  # noqa: F401
    from curobo.wrap.reacher.motion_gen import MotionGen, MotionGenConfig
    ...
"""

import torch


def _quat_conjugate(q):
    """q = [x, y, z, w] -> [-x, -y, -z, w]"""
    return torch.cat([-q[..., :3], q[..., 3:4]], dim=-1)


def _quat_rotate(q, v):
    """Rotate vector v by quaternion q. q = [x, y, z, w]"""
    q_xyz = q[..., :3]
    q_w = q[..., 3:4]
    t = 2.0 * torch.cross(q_xyz, v, dim=-1)
    return v + q_w * t + torch.cross(q_xyz, t, dim=-1)


class PoseInversePyTorch(torch.autograd.Function):
    @staticmethod
    def forward(ctx, position, quaternion, out_position, out_quaternion,
                adj_position, adj_quaternion):
        shape_p = position.shape
        shape_q = quaternion.shape
        pos = position.view(-1, 3)
        quat = quaternion.view(-1, 4)

        inv_quat = _quat_conjugate(quat)
        inv_pos = -_quat_rotate(inv_quat, pos)

        if out_position is None:
            out_position = torch.zeros_like(position)
        if out_quaternion is None:
            out_quaternion = torch.zeros_like(quaternion)

        out_position.copy_(inv_pos.view(shape_p))
        out_quaternion.copy_(inv_quat.view(shape_q))

        ctx.save_for_backward(position, quaternion)
        ctx.shape_p = shape_p
        ctx.shape_q = shape_q
        return out_position, out_quaternion

    @staticmethod
    def backward(ctx, grad_out_position, grad_out_quaternion):
        position, quaternion = ctx.saved_tensors
        pos = position.view(-1, 3).detach().requires_grad_(True)
        quat = quaternion.view(-1, 4).detach().requires_grad_(True)

        with torch.enable_grad():
            inv_quat = _quat_conjugate(quat)
            inv_pos = -_quat_rotate(inv_quat, pos)

        g_pos_flat = grad_out_position.view(-1, 3)
        g_quat_flat = grad_out_quaternion.view(-1, 4)

        grads = torch.autograd.grad(
            outputs=[inv_pos, inv_quat],
            inputs=[pos, quat],
            grad_outputs=[g_pos_flat, g_quat_flat],
            allow_unused=True,
        )

        g_p = grads[0].view(ctx.shape_p) if grads[0] is not None else None
        g_q = grads[1].view(ctx.shape_q) if grads[1] is not None else None
        return g_p, g_q, None, None, None, None


def _pose_inverse_pytorch(position, quaternion, out_position=None,
                          out_quaternion=None, adj_position=None,
                          adj_quaternion=None):
    if out_position is None:
        out_position = torch.zeros_like(position)
    if out_quaternion is None:
        out_quaternion = torch.zeros_like(quaternion)
    if adj_position is None:
        adj_position = torch.zeros_like(position)
    if adj_quaternion is None:
        adj_quaternion = torch.zeros_like(quaternion)
    return PoseInversePyTorch.apply(
        position, quaternion, out_position, out_quaternion,
        adj_position, adj_quaternion
    )


def _patch_transform_module():
    import curobo.geom.transform as ct
    ct.PoseInverse = PoseInversePyTorch

    original_pose_inverse = ct.pose_inverse

    def patched_pose_inverse(pose, out_pose=None):
        position = pose[..., :3]
        quaternion = pose[..., 3:]
        out_position = out_pose[..., :3] if out_pose is not None else None
        out_quaternion = out_pose[..., 3:] if out_pose is not None else None
        inv_pos, inv_quat = _pose_inverse_pytorch(
            position, quaternion, out_position, out_quaternion
        )
        return torch.cat([inv_pos, inv_quat], dim=-1)

    ct.pose_inverse = patched_pose_inverse


_patch_transform_module()
