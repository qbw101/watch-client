/**
 * 加密栈自检：把「表端算出的密钥为什么和服务端对不上」从推断变成实测。
 *
 * 为什么需要它：HELLO 握手帧是**明文 JSON**，所以「握手成功」完全不能说明双方算出
 * 了同一把会话密钥 —— 而密钥不一致的表现恰恰是每一帧都 `doFinal failed`。链路上
 * 看一切正常，只有把中间值掏出来才能定位。
 *
 * 设计要点：不做跨端对比（那需要同时控制两端），而是用**确定性测试向量**，让表端
 * 把 HKDF 和 GCM 的输出直接打出来。同样的输入在 Python 侧算一遍就能逐字节比对，
 * 从而判定表端的原语是否符合标准、以及密钥协商路径有没有走偏。
 *
 * 六项检查构成一棵判定树：
 *   ① getEncoded() 的形状   —— 是不是 44 字节标准 SPKI
 *   ② convertKey 往返       —— 裸公钥切出来再装回去，能否还原
 *   ③ ECDH 原生自洽         —— A×B 是否等于 B×A
 *   ④ 经「裸公钥重建」协商  —— 真实握手走的路径，结果必须等于 ③  ★ 关键
 *   ⑤ HKDF 固定向量         —— 与 Python 逐字节对比
 *   ⑥ GCM 固定向量 + 回环   —— 与 Python 逐字节对比
 *
 * ④ 失败 = importPublicKey 有 bug；③④ 通过而 ⑤⑥ 与 Python 不符 = 原语不对；
 * 全通过 = 表端加密栈自洽，要往别处找。
 *
 * 触发方式：应用启动时跑一次，结果写进 hilog（TAG=CryptoDiag）。不碰网络、不碰配置。
 * 定位完这个问题后应当移除（或在配置页加开关），它每次启动都会占约十行日志。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'CryptoDiag';

/** 与 WireCrypto 保持一致：X25519 SubjectPublicKeyInfo 的固定 DER 前缀 */
const SPKI_PREFIX: number[] = [
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00
];

/** 与 bridge/crypto.py 的 HKDF_INFO 严格一致 */
const HKDF_INFO: string = 'douyin-watch-bridge/v1';

const TAG_SIZE: number = 16;

function toHex(bytes: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const h: string = bytes[i].toString(16);
    out += (h.length === 1 ? '0' : '') + h;
  }
  return out;
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

/** 确定性测试向量：0x01, 0x02, ... , 0x20 */
function seq(n: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    out[i] = (i + 1) & 0xff;
  }
  return out;
}

async function sha8(data: Uint8Array): Promise<string> {
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  await md.update({ data: data });
  const digest: Uint8Array = (await md.digest()).data;
  return toHex(digest.slice(0, 8));
}

/** 与 WireCrypto.importPublicKey 完全相同的步骤 —— 自检要复现真实路径才有意义 */
async function rebuildPublic(
  generator: cryptoFramework.AsyKeyGenerator,
  raw: Uint8Array
): Promise<cryptoFramework.PubKey> {
  const der: Uint8Array = new Uint8Array(SPKI_PREFIX.length + raw.length);
  der.set(new Uint8Array(SPKI_PREFIX), 0);
  der.set(raw, SPKI_PREFIX.length);
  const pair: cryptoFramework.KeyPair = await generator.convertKey({ data: der }, null);
  return pair.pubKey;
}

export async function runCryptoDiag(): Promise<void> {
  hilog.info(DOMAIN, TAG, '====== 加密自检开始 ======');

  let gen: cryptoFramework.AsyKeyGenerator;
  let a: cryptoFramework.KeyPair;
  let b: cryptoFramework.KeyPair;
  try {
    gen = cryptoFramework.createAsyKeyGenerator('X25519');
    a = await gen.generateKeyPair();
    b = await gen.generateKeyPair();
  } catch (err) {
    hilog.error(DOMAIN, TAG, '生成密钥对失败，自检中止: %{public}s', (err as Error).message);
    return;
  }

  // ① getEncoded() 的形状：长度与头部字节
  let aDer: Uint8Array = new Uint8Array(0);
  try {
    aDer = a.pubKey.getEncoded().data;
    const head: Uint8Array = aDer.slice(0, Math.min(16, aDer.length));
    const matched: boolean = sameBytes(aDer.slice(0, 12), new Uint8Array(SPKI_PREFIX));
    hilog.info(
      DOMAIN,
      TAG,
      '① getEncoded 长度=%{public}d 前16字节=%{public}s 与标准SPKI前缀一致=%{public}s',
      aDer.length,
      toHex(head),
      matched ? '是' : '否'
    );
  } catch (err) {
    hilog.error(DOMAIN, TAG, '① 失败: %{public}s', (err as Error).message);
  }

  // ② convertKey 往返：切出裸公钥再补头装回去，看是否与原始 DER 完全一致
  try {
    const raw: Uint8Array = aDer.slice(aDer.length - 32);
    const restored: cryptoFramework.PubKey = await rebuildPublic(gen, raw);
    const der2: Uint8Array = restored.getEncoded().data;
    hilog.info(
      DOMAIN,
      TAG,
      '② 裸公钥长度=%{public}d 重建后长度=%{public}d 与原始DER一致=%{public}s',
      raw.length,
      der2.length,
      sameBytes(aDer, der2) ? '是' : '否'
    );
  } catch (err) {
    hilog.error(DOMAIN, TAG, '② 失败: %{public}s', (err as Error).message);
  }

  // ③ ECDH 自洽：两边都用框架原生公钥
  const agreement: cryptoFramework.KeyAgreement = cryptoFramework.createKeyAgreement('X25519');
  let sharedNative: Uint8Array = new Uint8Array(0);
  try {
    const x: Uint8Array = (await agreement.generateSecret(a.priKey, b.pubKey)).data;
    const y: Uint8Array = (await agreement.generateSecret(b.priKey, a.pubKey)).data;
    sharedNative = x;
    hilog.info(
      DOMAIN,
      TAG,
      '③ ECDH 原生自洽=%{public}s shared长度=%{public}d 指纹=%{public}s',
      sameBytes(x, y) ? '是' : '否',
      x.length,
      await sha8(x)
    );
  } catch (err) {
    hilog.error(DOMAIN, TAG, '③ 失败: %{public}s', (err as Error).message);
  }

  // ④ 真实握手路径：对端公钥是「裸 32 字节 + 重建」，结果必须等于 ③
  try {
    const bDer: Uint8Array = b.pubKey.getEncoded().data;
    const bRaw: Uint8Array = bDer.slice(bDer.length - 32);
    const bPub: cryptoFramework.PubKey = await rebuildPublic(gen, bRaw);
    const z: Uint8Array = (await agreement.generateSecret(a.priKey, bPub)).data;
    hilog.info(
      DOMAIN,
      TAG,
      '④ 经裸公钥重建协商 shared长度=%{public}d 与③一致=%{public}s 指纹=%{public}s',
      z.length,
      sameBytes(z, sharedNative) ? '是' : '否',
      await sha8(z)
    );
  } catch (err) {
    hilog.error(DOMAIN, TAG, '④ 失败: %{public}s', (err as Error).message);
  }

  // ⑤ HKDF 固定向量：key=0x01..0x20  salt=全零32字节  info='douyin-watch-bridge/v1'
  try {
    const info: Uint8Array = new util.TextEncoder().encodeInto(HKDF_INFO);
    const kdf: cryptoFramework.Kdf = cryptoFramework.createKdf('HKDF|SHA256|EXTRACT_AND_EXPAND');
    const spec: cryptoFramework.HKDFSpec = {
      algName: 'HKDF',
      key: seq(32),
      salt: new Uint8Array(32),
      info: info,
      keySize: 32
    };
    const out: Uint8Array = (await kdf.generateSecret(spec)).data;
    hilog.info(
      DOMAIN,
      TAG,
      '⑤ HKDF info长度=%{public}d 输出长度=%{public}d 结果=%{public}s',
      info.length,
      out.length,
      toHex(out)
    );
  } catch (err) {
    hilog.error(DOMAIN, TAG, '⑤ 失败: %{public}s', (err as Error).message);
  }

  // ⑥ GCM 固定向量 + 回环：key=全零32  iv=全零12  aad=空  plaintext='hello watch'
  try {
    const keyGen: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
    const key: cryptoFramework.SymKey = await keyGen.convertKey({ data: new Uint8Array(32) });
    const iv: Uint8Array = new Uint8Array(12);
    const plain: Uint8Array = new util.TextEncoder().encodeInto('hello watch');

    const encrypter: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const encParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: new Uint8Array(TAG_SIZE) }
    };
    await encrypter.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, encParams);
    const enc: Uint8Array = (await encrypter.doFinal({ data: plain })).data;
    hilog.info(
      DOMAIN,
      TAG,
      '⑥ GCM 明文长度=%{public}d 密文长度=%{public}d 结果=%{public}s',
      plain.length,
      enc.length,
      toHex(enc)
    );

    // 用同一把 key/iv 解回来 —— 走和 BridgeLink 相同的拆包方式（末尾 16 字节是 tag）
    const decrypter: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const decParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: enc.slice(enc.length - TAG_SIZE) }
    };
    await decrypter.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, decParams);
    const dec: Uint8Array = (await decrypter.doFinal({ data: enc.slice(0, enc.length - TAG_SIZE) })).data;
    hilog.info(
      DOMAIN,
      TAG,
      '⑥ GCM 回环 明文恢复一致=%{public}s 明文=%{public}s',
      sameBytes(dec, plain) ? '是' : '否',
      new util.TextDecoder().decodeToString(dec)
    );
  } catch (err) {
    hilog.error(DOMAIN, TAG, '⑥ 失败: %{public}s', (err as Error).message);
  }

  hilog.info(DOMAIN, TAG, '====== 加密自检结束 ======');
}
