/**
 * 链路加密的手表端实现：X25519 密钥交换 + HKDF-SHA256 + AES-256-GCM。
 *
 * 与 bridge/crypto.py 严格配对。构造函数里那句 `AES256|GCM|NoPadding` 和
 * Python 那边的 `AESGCM` 必须产出完全一致的字节，任何一侧变更都要重跑
 * scripts/tcp_smoke.py。
 *
 * 为什么不用 TLSSocket：TLS 要证书，证书要 SAN，而手表可能用局域网 IP、
 * 也可能用穿透服务商给的域名连过来 —— SAN 在签发时无法预知。X25519 没有
 * 这个问题，也不引入证书的签发/过期/轮换这一整套生命周期。
 *
 * nonce 的构造（12 字节 = 4 字节方向 + 8 字节计数器）和 Python 侧一致：
 * 两个方向共用一把密钥时，方向前缀保证 nonce 不会重复 —— GCM 里同 key 同
 * nonce 会直接泄露明文异或，这是这套算法最致命的坑。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'WireCrypto';

/** 逐帧对账用的短十六进制串（只取头部几个字节，够区分帧即可） */
function headHex(bytes: Uint8Array, n: number): string {
  const count: number = Math.min(n, bytes.length);
  let out: string = '';
  for (let i = 0; i < count; i++) {
    const h: string = bytes[i].toString(16);
    out += (h.length === 1 ? '0' : '') + h;
  }
  return out;
}

/** X25519 SubjectPublicKeyInfo 的固定 DER 前缀，后面接 32 字节裸公钥 */
const X25519_SPKI_PREFIX: number[] = [
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00
];

const DIR_SERVER_TO_CLIENT: number = 1;
const DIR_CLIENT_TO_SERVER: number = 2;
const NONCE_SIZE: number = 12;
const TAG_SIZE: number = 16;

const base64: util.Base64Helper = new util.Base64Helper();

/** 握手里要交换的材料 */
export interface HandshakeMaterial {
  /** 本方临时公钥（32 字节裸字节） */
  publicKey: Uint8Array;
  /** 本方随机数（16 字节），参与盐的构造 */
  nonce: Uint8Array;
  /** 本方私钥，协商时要拿它和对方公钥算出共享密钥 */
  privateKey: cryptoFramework.PriKey;
}

/** 生成一组临时密钥。每次连接都换一对，所以录下的流量事后拿到 token 也解不开。 */
export async function createHandshakeMaterial(): Promise<HandshakeMaterial> {
  const generator: cryptoFramework.AsyKeyGenerator = cryptoFramework.createAsyKeyGenerator('X25519');
  const keyPair: cryptoFramework.KeyPair = await generator.generateKeyPair();
  const spki: Uint8Array = keyPair.pubKey.getEncoded().data;
  // getEncoded() 给的是 DER，X25519 的 SPKI 固定 44 字节 = 12 字节头部 + 32 字节裸公钥。
  // 协议里传裸公钥（省 12 字节，也和 Python 侧的 bytes 表示一致），所以这里切掉头部。
  const raw: Uint8Array = spki.slice(spki.length - 32);
  const random: cryptoFramework.Random = cryptoFramework.createRandom();
  const nonce: Uint8Array = random.generateRandomSync(16).data;
  return { publicKey: raw, nonce, privateKey: keyPair.priKey };
}

/** 把对端给的 32 字节裸公钥还原成 Key 对象：补回 SPKI 头再让框架解析 */
async function importPublicKey(raw: Uint8Array): Promise<cryptoFramework.PubKey> {
  if (raw.length !== 32) {
    throw new Error(`对端公钥长度不对：${raw.length}`);
  }
  const der: Uint8Array = new Uint8Array(X25519_SPKI_PREFIX.length + raw.length);
  der.set(new Uint8Array(X25519_SPKI_PREFIX), 0);
  der.set(raw, X25519_SPKI_PREFIX.length);
  const generator: cryptoFramework.AsyKeyGenerator = cryptoFramework.createAsyKeyGenerator('X25519');
  const pair: cryptoFramework.KeyPair = await generator.convertKey({ data: der }, null);
  return pair.pubKey;
}

/**
 * 双方各算一次，得到同一个 32 字节会话密钥。
 *
 * 盐同时包含双方的随机数 —— 只绑一方的随机数的话，攻击者可以固定自己那半
 * 来压缩搜索空间。
 */
export async function deriveSessionKey(
  material: HandshakeMaterial,
  peerPublicKey: Uint8Array,
  clientNonce: Uint8Array,
  serverNonce: Uint8Array
): Promise<Uint8Array> {
  const peer: cryptoFramework.PubKey = await importPublicKey(peerPublicKey);
  const agreement: cryptoFramework.KeyAgreement = cryptoFramework.createKeyAgreement('X25519');
  const shared: Uint8Array = (await agreement.generateSecret(material.privateKey, peer)).data;

  const salt: Uint8Array = new Uint8Array(clientNonce.length + serverNonce.length);
  salt.set(clientNonce, 0);
  salt.set(serverNonce, clientNonce.length);

  const kdf: cryptoFramework.Kdf = cryptoFramework.createKdf('HKDF|SHA256|EXTRACT_AND_EXPAND');
  const info: Uint8Array = new util.TextEncoder().encodeInto('douyin-watch-bridge/v1');
  const spec: cryptoFramework.HKDFSpec = {
    algName: 'HKDF',
    key: shared,
    salt: salt,
    info: info,
    keySize: 32
  };
  return (await kdf.generateSecret(spec)).data;
}

/**
 * 一条连接的加解密通道。
 *
 * 加密方向用 DIR_CLIENT_TO_SERVER、解密方向用 DIR_SERVER_TO_CLIENT —— 这两个
 * 反了不会报错，只会让所有帧都解不开，所以单独写成两个具名常量。
 */
export class SecureChannel {
  private key: cryptoFramework.SymKey;
  private sendCounter: number = 0;
  private receiveCounter: number = 0;

  private constructor(key: cryptoFramework.SymKey) {
    this.key = key;
  }

  static async create(rawKey: Uint8Array): Promise<SecureChannel> {
    const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
    const symKey: cryptoFramework.SymKey = await generator.convertKey({ data: rawKey });
    return new SecureChannel(symKey);
  }

  private static nonce(direction: number, counter: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(NONCE_SIZE);
    out[0] = (direction >>> 24) & 0xff;
    out[1] = (direction >>> 16) & 0xff;
    out[2] = (direction >>> 8) & 0xff;
    out[3] = direction & 0xff;
    // 计数器占高 4 字节的后续 8 字节。JS 的位运算只有 32 位，所以手动拆成两半。
    const high: number = Math.floor(counter / 4294967296);
    const low: number = counter % 4294967296;
    const view: DataView = new DataView(out.buffer);
    view.setUint32(4, high, false);
    view.setUint32(8, low, false);
    return out;
  }

  /**
   * 加密一帧的载荷，返回「密文 ‖ 认证标签」。
   *
   * nonce 不进密文 —— 两端各自按方向+计数器推导，省 12 字节。代价是计数器
   * 必须严格同步，所以解密失败时调用方要断开连接而不是继续往下读。
   */
  async encrypt(plaintext: Uint8Array): Promise<Uint8Array> {
    const counter: number = this.sendCounter;
    const nonce: Uint8Array = SecureChannel.nonce(DIR_CLIENT_TO_SERVER, counter);
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce },
      aad: { data: new Uint8Array(0) },
      authTag: { data: new Uint8Array(TAG_SIZE) }
    };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, this.key, params);
    // 注意：本机（WATCH 5，API 版本以实机为准）的 GCM 必须整段走 doFinal()。
    // 试过 update() 喂正文 + doFinal(null) 收尾的标准写法，实测 update 期间数据
    // 没有真正进入运算，doFinal 验签必挂；单次 doFinal 对 7KB 大帧也一直正常。
    const out: Uint8Array = (await cipher.doFinal({ data: plaintext })).data;
    // 逐帧对账：把本帧实际用的 nonce 序号和密文头部打出来，和服务端的「发→」日志对着看
    hilog.info(DOMAIN, TAG, '发→ counter=%{public}d 明文=%{public}d 密文=%{public}d nonce=%{public}s 头=%{public}s',
      counter, plaintext.length, out.length, headHex(nonce, 4), headHex(out, 8));
    this.sendCounter += 1;
    return out;
  }

  /** 解密一帧的载荷。密文最后 16 字节是认证标签，要单独交给 GCM。 */
  async decrypt(blob: Uint8Array): Promise<Uint8Array> {
    if (blob.length < TAG_SIZE) {
      throw new Error(`密文过短：${blob.length}`);
    }
    const counter: number = this.receiveCounter;
    const head: string = headHex(blob, 8);
    const body: Uint8Array = blob.slice(0, blob.length - TAG_SIZE);
    const tag: Uint8Array = blob.slice(blob.length - TAG_SIZE);
    const nonce: Uint8Array = SecureChannel.nonce(DIR_SERVER_TO_CLIENT, counter);
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce },
      aad: { data: new Uint8Array(0) },
      authTag: { data: tag }
    };
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, this.key, params);
    let out: Uint8Array;
    try {
      if (body.length === 0) {
        // 空载荷帧（心跳 PING/PONG：16 字节全是认证标签，没有正文）在这里必须走
        // doFinal(null)—— 传空 DataBlob 会直接抛 doFinal failed，而心跳一回 PONG
        // 就解不开，接收计数器从此永久错位，表现成「一发消息就 do final failed、
        // 然后连不上」（发消息会让链路静默 6 秒，正好触发一轮心跳）。
        // 框架验完签后返回 null 表示没有明文，这里兜成空数组。
        const tail: cryptoFramework.DataBlob | null = await cipher.doFinal(null);
        out = tail === null ? new Uint8Array(0) : tail.data;
      } else {
        // 单次 doFinal（不能拆 update + doFinal，实测该平台上 update 期间数据
        // 没有真正进入运算，验签必挂；单次 doFinal 对 7KB 大帧也一直正常）。
        out = (await cipher.doFinal({ data: body })).data;
      }
    } catch (err) {
      // 失败时把 nonce 序号和密文头一起打出来 —— 这两样是判断「计数器错位」还是
      // 「密钥不对」的全部依据，少了任何一个都只能靠猜。
      const e: Error = err as Error;
      hilog.warn(DOMAIN, TAG, '收← 解密失败 counter=%{public}d 密文=%{public}d nonce=%{public}s 头=%{public}s 原因=%{public}s',
        counter, blob.length, headHex(nonce, 4), head, e.message);
      throw e;
    }
    hilog.info(DOMAIN, TAG, '收← counter=%{public}d 明文=%{public}d 密文=%{public}d nonce=%{public}s 头=%{public}s',
      counter, out.length, blob.length, headHex(nonce, 4), head);
    this.receiveCounter += 1;
    return out;
  }
}

/** 明文模式：接口与 SecureChannel 相同，调用方不用分支 */
export class PlainChannel {
  async encrypt(plaintext: Uint8Array): Promise<Uint8Array> {
    return plaintext;
  }

  async decrypt(blob: Uint8Array): Promise<Uint8Array> {
    return blob;
  }
}

export function toBase64(bytes: Uint8Array): string {
  return base64.encodeToStringSync(bytes);
}

export function fromBase64(text: string): Uint8Array {
  return base64.decodeSync(text, util.Type.BASIC);
}
