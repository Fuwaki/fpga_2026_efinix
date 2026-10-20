// Shared video / DDR frame constants for capture + display refactor.
`ifndef VIDEO_PKG_VH
`define VIDEO_PKG_VH

// Sensor + DDR layer 0 (after 2x2 binning)
`define CAM_ACTIVE_W        1280
`define CAM_ACTIVE_H        720
`define CAM_PIXEL_BYTES     4
`define DDR_CAM0_BASE       32'h00000
`define DDR_CAM_FB_NUM      3

// HDMI panel (unchanged CEA 1080p60)
`define DISP_HRES           1920
`define DISP_VRES           1080

// Center 720p content in 1080p frame (full-pixel coordinates)
`define DISP_H_MARGIN       ((`DISP_HRES - `CAM_ACTIVE_W) / 2)
`define DISP_V_MARGIN       ((`DISP_VRES - `CAM_ACTIVE_H) / 2)

`endif
