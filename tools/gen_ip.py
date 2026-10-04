#!/usr/bin/env python3
"""
gen_ip.py - 无 IDE 生成 Efinity IP 核 (调用 IP Manager 的 python API)

Efinity 官方只提供 GUI 的 IP Configuration Wizard；本脚本直接调用它的内部
python API (gui.api_wrapper -> efx_ipmgr.api_v2.IPManagerBackend)，在命令行下
等价完成 "选 IP -> 改参数 -> Generate"。

用法:
  # 列出可用 IP
  tools/gen_ip.py --list

  # 打印某个 IP 的全部参数与默认值
  tools/gen_ip.py --vlnv soc/efx_soc:3.4.0 --dump-params

  # 生成 IP 到当前工程 (产物落在 <out>/ip/<gen-name>/)
  tools/gen_ip.py --vlnv soc/efx_soc:3.4.0 --gen-name soc_inst0 \
                  --param DDR=1'b0 --param I2C0=1'b1

参数:
  --out DIR        工程根目录 (含 fpga_src.xml / fpga_src.peri.xml)，默认脚本上一级
  --device/--family 目标器件，默认 Ti60F225 / Titanium
  --settings-json F  以已有 settings.json 为起点 (等价 GUI 的 Import IP)
"""

import argparse
import os
import sys
from pathlib import Path

EFINITY_HOME = Path(os.environ.get('EFINITY_HOME', '/opt/efinity/2026.1'))
IPM_BIN = EFINITY_HOME / 'ipm' / 'bin'

sys.path.insert(0, str(IPM_BIN))
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from common.util import set_efinity_user_dir_env          # noqa: E402
from common.logger import Logger                          # noqa: E402

set_efinity_user_dir_env()
_log_dir = Path(os.environ['EFINITY_USER_DIR'], 'ipm', 'log')
_log_dir.mkdir(parents=True, exist_ok=True)
Logger.setup_logger(log_path_str=str(_log_dir),
                    config_path_str=str(EFINITY_HOME / 'ipm' / 'log' / 'config.ini'))

from gui import api_wrapper                                        # noqa: E402
from efx_ipmgr.production_api.type.vlnv_type import VLNV           # noqa: E402
from efx_ipmgr.api_v2 import IPManagerBackend, Resolve             # noqa: E402

RELATIVE_PATH = 2   # gui.enums.ExternalFileStorage.RELATIVE_PATH


def parse_vlnv(text, lib=None, ver=None):
    """'soc/efx_soc:3.4.0' 或 'efx_soc' (配合 --library/--version)"""
    spec = text
    if ':' in spec:
        spec, ver = spec.rsplit(':', 1)
    if '/' in spec:
        lib, name = spec.split('/', 1)
    else:
        name = spec
    if not lib:
        raise SystemExit(f'需要 --library 或 lib/name 形式: {text}')
    return VLNV(vendor='efinixinc.com', library=lib, name=name,
                version=ver or '')


def find_vlnv(ips, name, lib=None):
    hits = [v for v in ips if v.name == name and (lib is None or v.library == lib)]
    if not hits:
        raise SystemExit(f'IP 未找到: {name}')
    return sorted(hits, key=lambda v: v.version)[-1]


def apply_params(params, overrides):
    """把 NAME=VALUE 覆盖到参数表上 (ParameterTemplate 是 NamedTuple，用 _replace 复制)"""
    unknown = set(overrides) - {p.name for p in params}
    if unknown:
        raise SystemExit('未知参数: ' + ', '.join(sorted(unknown)))
    out = []
    for p in params:
        out.append(p._replace(value=overrides[p.name],
                              default_value=overrides[p.name])
                   if p.name in overrides else p)
    return out


def main():
    ap = argparse.ArgumentParser(description='无 IDE 生成 Efinity IP 核')
    ap.add_argument('--vlnv', help="如 soc/efx_soc:3.4.0")
    ap.add_argument('--library')
    ap.add_argument('--version')
    ap.add_argument('--gen-name', help='生成的模块名 (ip/<gen-name>/)')
    ap.add_argument('--out', default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument('--device', default='Ti60F225')
    ap.add_argument('--family', default='Titanium')
    ap.add_argument('--param', action='append', default=[], metavar='NAME=VALUE')
    ap.add_argument('--settings-json')
    ap.add_argument('--list', action='store_true', help='列出所有可用 IP')
    ap.add_argument('--dump-params', action='store_true', help='打印 IP 参数与默认值')
    args = ap.parse_args()

    api_wrapper.init_console(None)
    api_wrapper.get_option()
    ips, _ = api_wrapper.get_list_of_ips()

    if args.list:
        for v in sorted(ips, key=lambda v: (v.library, v.name)):
            print(f'{v.library}/{v.name}:{v.version}')
        return 0

    if not args.vlnv:
        raise SystemExit('缺少 --vlnv (或用 --list)')

    if args.settings_json:
        vlnv = api_wrapper.get_vlnv_from_settings_json(args.settings_json)
    else:
        vlnv = parse_vlnv(args.vlnv, args.library, args.version)
    be = IPManagerBackend.singleton()
    assert be.is_vlnv_valid(vlnv), f'VLNV 不在 IP 目录中: {vlnv}'
    print(f'[gen_ip] {vlnv}')

    # 关键: 先 load() 才会真正解析 ipxact / 载入 pickle，否则参数表是空的
    comp, ct, graph, from_pickle = be.load(vlnv, device=args.device, family=args.family)
    print(f'[gen_ip] load 完成 (pickle={from_pickle}), 参数 {len(ct.parameters)} 项')

    overrides = {}
    for kv in args.param:
        k, _, v = kv.partition('=')
        overrides[k.strip()] = v.strip()

    if args.dump_params:
        params = api_wrapper.get_ip_params(vlnv, device_name=args.device, family_name=args.family)
        if overrides:
            params = apply_params(params, overrides)
            vr, params, _, _ = api_wrapper.validate_params(
                vlnv, params, device_name=args.device, family_name=args.family)
            if not vr.result:
                print('[gen_ip] 参数校验失败:\n' + vr.error_tuple_msg, file=sys.stderr)
                return 1
        for p in sorted(params, key=lambda p: p.name):
            mark = ' *' if p.name in overrides else ''
            print(f'{p.resolve:10s} {p.name:28s} = {p.default_value!r}   -> {p.value!r}{mark}')
        print('\nfilesets:', list(ct.filesets))
        return 0

    if not args.gen_name:
        raise SystemExit('缺少 --gen-name')

    params = api_wrapper.get_ip_params(vlnv, device_name=args.device, family_name=args.family)
    params = apply_params(params, overrides)

    # 参数之间有条件依赖 (例如 DDR=0 会隐藏 DDRSize)，校验一次后再覆盖一遍
    vr, params, comp, graph = api_wrapper.validate_params(
        vlnv, params, device_name=args.device, family_name=args.family)
    if not vr.result:
        print('[gen_ip] 参数校验失败:\n' + vr.error_tuple_msg, file=sys.stderr)
        return 1
    params = apply_params(params, overrides)

    filesets = [f.fileset_template for f in api_wrapper.get_ip_filesets(vlnv)]

    out = Path(args.out).resolve()
    res = api_wrapper.generate_ip(
        vlnv=vlnv,
        params=params,
        filesets=filesets,
        out_path=out,
        user_ip_path=out,
        external_file_path_option=RELATIVE_PATH,
        gen_name=args.gen_name,
        device_name=args.device,
        family_name=args.family,
        project_name=Path(args.out).name,
        peri_xml_file_path=str(out / 'fpga_src.peri.xml'),
        project_xml_path=str(out / 'fpga_src.xml'),
        postmap_module_enable='false',
        ooc_synthesis_option=0,
    )
    print(f'[gen_ip] generate_ip -> {res}')
    if str(res).endswith('SUCCESS'):
        print(f'[gen_ip] 产物: {out / "ip" / args.gen_name}')
        return 0
    return 1


if __name__ == '__main__':
    sys.exit(main())
