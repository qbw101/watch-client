/**
 * 桥接协议的手表端实现：帧编解码 + 流式分帧。
 *
 * 与 bridge/protocol.py 一一对应。两边的字节布局必须完全一致，改动时
 * 一定要同时改，并且用 scripts/tcp_smoke.py 跑一遍对照。
 *
 * 帧头固定 8 字节，大端：
 *     偏移 0  4 字节  载荷长度（不含帧头）
 *     偏移 4  1 字节  帧类型
 *     偏移 5  2 字节  请求 id（0 表示服务端主动推送）
 *     偏移 7  1 字节  标志
 *
 * TCP 是字节流：一次收包可能只有半帧，也可能一口气三帧半。所以所有收到的数据
 * 都必须先丢进 FrameParser 攒着，由它按帧切 —— 绝不能假设「一次回调 = 一帧」。
 */
import { util } from '@kit.ArkTS';

export const HEADER_SIZE: number = 8;

export const TYPE_HELLO: number = 0x01;
export const TYPE_REQ: number = 0x02;
export const TYPE_RES: number = 0x03;
export const TYPE_IMAGE: number = 0x04;
export const TYPE_PING: number = 0x05;
export const TYPE_PONG: number = 0x06;

export const FLAG_MORE: number = 0x01;
export const FLAG_ERROR: number = 0x02;
export const FLAG_PUSH: number = 0x04;

/** 必须与服务端 PROTOCOL_VERSION 一致，不一致时握手会被拒 */
export const PROTOCOL_VERSION: number = 1;
/** 单帧载荷上限，与服务端一致 */
export const MAX_PAYLOAD: number = 4 * 1024 * 1024;

const encoder: util.TextEncoder = new util.TextEncoder();
const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });

/** 一帧 */
export interface Frame {
  type: number;
  reqId: number;
  flags: number;
  payload: Uint8Array;
}

/** JSON 载荷统一走这里，保证两边都是 UTF-8 */
export function encodeJsonText(text: string): Uint8Array {
  return encoder.encodeInto(text);
}

export function decodeJsonText(payload: Uint8Array): string {
  return decodeUtf8(payload);
}

/**
 * 按 UTF-8 解一段字节。
 *
 * 与 decodeJsonText 是同一件事，单独列出来只是为了调用点的语义：批量表情缩略图
 * 的载荷里除了 JSON 头，还夹着 utf8 的标识串，那里读起来不该叫「解析 JSON」。
 */
export function decodeUtf8(payload: Uint8Array): string {
  return decoder.decodeToString(payload);
}

/** 把一帧拼成字节串 */
export function packFrame(frameType: number, reqId: number, payload: Uint8Array, flags: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(HEADER_SIZE + payload.length);
  const view: DataView = new DataView(out.buffer);
  view.setUint32(0, payload.length, false);
  view.setUint8(4, frameType);
  view.setUint16(5, reqId, false);
  view.setUint8(7, flags);
  out.set(payload, HEADER_SIZE);
  return out;
}

/** 按帧切分字节流 */
export class FrameParser {
  private buffer: Uint8Array = new Uint8Array(0);

  /** 喂入刚收到的字节。粘包、半包都在这里被吃掉。 */
  push(chunk: Uint8Array): void {
    if (chunk.length === 0) {
      return;
    }
    const merged: Uint8Array = new Uint8Array(this.buffer.length + chunk.length);
    merged.set(this.buffer, 0);
    merged.set(chunk, this.buffer.length);
    this.buffer = merged;
  }

  /**
   * 取出一帧；数据还不够一帧时返回 null。
   *
   * 长度非法（超过上限）时抛错 —— 那说明对面不是我们的协议，继续读下去只会
   * 把内存吃光，调用方应该据此断开连接。
   */
  next(): Frame | null {
    if (this.buffer.length < HEADER_SIZE) {
      return null;
    }
    const view: DataView = new DataView(this.buffer.buffer, this.buffer.byteOffset, HEADER_SIZE);
    const length: number = view.getUint32(0, false);
    const frameType: number = view.getUint8(4);
    const reqId: number = view.getUint16(5, false);
    const flags: number = view.getUint8(7);
    if (length > MAX_PAYLOAD) {
      throw new Error(`帧长度非法：${length}`);
    }
    if (this.buffer.length < HEADER_SIZE + length) {
      return null;
    }
    const payload: Uint8Array = this.buffer.slice(HEADER_SIZE, HEADER_SIZE + length);
    this.buffer = this.buffer.slice(HEADER_SIZE + length);
    return { type: frameType, reqId, flags, payload };
  }

  /** 换连接时清空残留，避免把上一条连接的半帧当成新连接的开头 */
  reset(): void {
    this.buffer = new Uint8Array(0);
  }
}
