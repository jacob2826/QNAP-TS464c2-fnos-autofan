# 威联通TS-464C2 飞牛OS 自动调整风扇转速

`fnos-autofan.sh` 是一个 **单文件、一键式** 的自动风扇控制脚本，基于 **QNAP TS-464C2 + 飞牛 OS（fnOS）** 实机环境调试完成。

该脚本围绕 `qnap8528` 内核模块，提供从 **驱动编译安装 → 开机自启 → 风扇自动调速 → 状态检测 → 安全卸载** 的完整闭环，目标是：

* 低依赖（不依赖 fancontrol / lm-sensors 等工具）
* 易维护（系统或内核更新后可直接重跑修复）
* 行为可预期（所有操作、日志均在脚本内可见）

> 本项目以 TS-464C2 为唯一调试目标，其它型号不保证兼容性。

---

## 功能概览

脚本支持以下模式：

### 默认模式（安装 / 修复）

直接运行：

```bash
sudo bash fnos-autofan.sh
```

将执行：

* 拉取或更新 `qnap8528` 源码仓库
* 使用 Docker 编译并安装内核模块（调用上游 `build.sh`）
* 写入 `modprobe` 参数（`skip_hw_check=true`）
* 安装并启用驱动自启服务：`qnap8528-load.service`
* 安装并启用风扇守护服务：`qnap-fan-daemon.service`

该模式 **可反复运行**，用于系统或内核更新后的快速修复。

---

### 状态检测

```bash
sudo bash fnos-autofan.sh --status
```

输出内容包括：

* `qnap8528` 内核模块是否已加载
* 驱动 / 风扇守护 systemd 服务是否已安装、启用、运行
* 当前 PWM、风扇转速、温度传感器读数

---

### 安全满速模式（应急）

```bash
sudo bash fnos-autofan.sh --safe-max
```

行为：

* 停止自动风扇守护
* 立即将 PWM 设置为最大值（默认 255）

用于高温排障或确认硬件响应。

---

### 卸载

```bash
sudo bash fnos-autofan.sh --uninstall
```

行为：

* 停止并移除风扇守护及其 systemd unit
* 禁用并移除驱动自启配置
* 尝试卸载 `qnap8528` 模块
* 清理 fan2go 残留（若系统中存在）

卸载前会 **尽力将 PWM 设置到安全值**（默认 200，可配置），避免风扇停留在低转速。

---

## 可配置参数（环境变量）

示例：

```bash
sudo INTERVAL=5 MIN_PWM=76 MAX_PWM=255 HYST_C=2 MIN_HOLD_SEC=10 MAX_STEP=12 \
  SAFE_UNINSTALL_PWM=200 \
  bash fnos-autofan.sh
```

主要参数：

* `INTERVAL`：调速循环间隔（秒）
* `MIN_PWM / MAX_PWM`：PWM 下限 / 上限
* `HYST_C`：温度回差（℃）
* `MIN_HOLD_SEC`：调速后最小保持时间（秒）
* `MAX_STEP`：单次 PWM 最大变化量
* `SAFE_UNINSTALL_PWM`：卸载前设置的安全 PWM（0 表示跳过）

---

## 实时监控示例（1 秒刷新）

用于确认驱动、PWM、转速和温度是否正常工作：

```bash
while true; do
  clear
  echo "Time: $(date '+%F %T')"
  echo

  H_QNAP=$(for d in /sys/class/hwmon/hwmon*; do [ "$(cat "$d/name" 2>/dev/null)" = "qnap8528" ] && echo "$d" && break; done)
  H_CPU=$(for d in /sys/class/hwmon/hwmon*; do [ "$(cat "$d/name" 2>/dev/null)" = "coretemp" ] && echo "$d" && break; done)

  if [ -n "$H_QNAP" ]; then
    echo "[qnap8528]"
    echo "  pwm=$(cat $H_QNAP/pwm1 2>/dev/null)  rpm=$(cat $H_QNAP/fan1_input 2>/dev/null)"
    for f in temp1_input temp6_input temp11_input temp12_input; do
      [ -e "$H_QNAP/$f" ] && awk -v n="$f" -v x="$(cat $H_QNAP/$f)" 'BEGIN{printf "  %s=%.1fC\n", n, x/1000.0}'
    done
  else
    echo "[qnap8528] NOT FOUND"
  fi

  echo

  if [ -n "$H_CPU" ]; then
    awk -v x="$(cat $H_CPU/temp1_input 2>/dev/null)" 'BEGIN{printf "[coretemp] Package=%.1fC\n", x/1000.0}'
  else
    echo "[coretemp] NOT FOUND"
  fi

  sleep 1
done
```
