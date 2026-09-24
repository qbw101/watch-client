/**
 * 链路层的错误类型与错误码翻译。
 *
 * 单独放一个模块是为了让 BridgeLink（传输）和 BridgeSession（业务封装）共用同一个
 * 错误类 —— 两个类各自定义一份的话，上层拿到的东西就没法用 `instanceof` 判定了。
 *
 * `kind` 存在的理由很实际：手表上没法查日志，能做的只有「提示得足够具体、或者
 * 直接把用户送到配置页」。令牌错要跳配置页，网络不通要提供重试，服务端报错只能
 * 原样转述 —— 这三种处理完全不同，靠解析错误文本猜是不行的。
 */
import { BusinessError } from '@kit.BasicServicesKit';

/** 令牌被服务端拒绝，唯一有效的动作是回配置页重填 */
export const KIND_TOKEN: string = 'token';
/** 连不上、连到一半断了、域名解析不了 */
export const KIND_NETWORK: string = 'network';
/** 服务端明确回了错误（抖音会话没起、未找到会话等） */
export const KIND_SERVER: string = 'server';
/** 自己这边的超时：请求发出去了但没有应答 */
export const KIND_TIMEOUT: string = 'timeout';

export class BridgeError extends Error {
  kind: string;

  constructor(kind: string, message: string) {
    super(message);
    this.kind = kind;
  }
}

/**
 * 把任意异常归一成 BridgeError。
 *
 * 不用 `instanceof` 判断：ArkTS 里跨模块的 Error 子类在极少数情况下判定会失效，
 * 而失败路径上最不能接受的就是「明明有原因，却只剩下一个泛泛的失败」。
 */
export function asBridgeError(err: Object, fallbackKind: string): BridgeError {
  const typed: BridgeError = err as BridgeError;
  if (typed.kind !== undefined && typed.kind.length > 0 && typed.message !== undefined) {
    return typed;
  }
  const e: BusinessError = err as BusinessError;
  if (e.message !== undefined && e.message.length > 0) {
    return new BridgeError(fallbackKind, e.message);
  }
  return new BridgeError(fallbackKind, '未知错误');
}

/** 网络层错误码翻成人话：手表上没地方看日志，提示必须能直接指导操作 */
export function networkHint(err: BusinessError): string {
  const code: number = err.code;
  if (code === 2300004) {
    return '手表当前没有网络';
  }
  if (code === 2300006) {
    return '找不到这台电脑：检查地址里的 IP 是否写对';
  }
  if (code === 2300007) {
    return '连不上电脑：服务没启动，或不在同一个网络';
  }
  if (code === 2300028) {
    return '连接超时：电脑端可能正忙，稍后重试';
  }
  const detail: string = err.message !== undefined ? err.message : '';
  return detail.length > 0 ? `网络异常（${code}）：${detail}` : `网络异常（${code}）`;
}
