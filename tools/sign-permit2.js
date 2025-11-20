import * as dotenv from "dotenv";
import { ethers } from "ethers";

// -----------------------------------------------------------------------------
// 0) 解析命令行参数：--network=xxx --mode=xxx  --spender=<BRIDGE_ADDRESS>
// -----------------------------------------------------------------------------
const args = process.argv.slice(2);

function getArg(key, defaultValue) {
  const item = args.find(a => a.startsWith(`--${key}=`));
  return item ? item.split("=")[1] : defaultValue;
}

const NETWORK = getArg("network", "sepolia");  // 默认 sepolia
const MODE = getArg("mode", "2");          // 默认 batch
const SPENDER_ARG = getArg("spender", null);  // spender 地址（可选）

if (!["1", "2"].includes(MODE)) {
  console.error(`❌ Invalid mode: ${MODE}. Use --mode=1 or --mode=2`);
  process.exit(1);
}

console.log(`\n>>> NETWORK = ${NETWORK}`);
console.log(`>>> MODE     = ${MODE}\n`);

// -----------------------------------------------------------------------------
// 1) 加载 .env.<network>
// -----------------------------------------------------------------------------
dotenv.config({ path: `.env.${NETWORK}` });

const PRIVATE_KEY = process.env.DEPLOYER_PK;
if (!PRIVATE_KEY) {
  throw new Error(`DEPLOYER_PK not found in .env.${NETWORK}`);
}

// -----------------------------------------------------------------------------
// 2) Provider + Wallet
// -----------------------------------------------------------------------------
const provider = new ethers.JsonRpcProvider(
  process.env.RPC_URL || "https://sepolia.infura.io/v3/xxxx"
);

const signer = new ethers.Wallet(PRIVATE_KEY, provider);

// -----------------------------------------------------------------------------
// 3) Permit2 地址
// -----------------------------------------------------------------------------
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

// -----------------------------------------------------------------------------
// 4) 参数（你自己可以修改）
// -----------------------------------------------------------------------------

// vToken
const TOKEN = "0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D";

// LINK
const LINK = "0x779877A7B0D9E8603169DdbD7836e478b4624789";

// 授权额度（最大值）
const MAX_VTOKEN_AMOUNT = ethers.parseUnits("100", 18);
const MAX_LINK_AMOUNT   = ethers.parseUnits("2", 18);
const MAX_SINGLE_AMOUNT = ethers.parseUnits("100", 18);

// deadline
const DEADLINE = Math.floor(Date.now() / 1000) + 3600; // 1 小时有效

// nonce
const NONCE = Math.floor(Math.random() * 1e12);

// -----------------------------------------------------------------------------
// 5) EIP712 typedData + 签名
// -----------------------------------------------------------------------------
async function main() {
  const { chainId } = await provider.getNetwork();

  const domain = {
    name: "Permit2",
    chainId: Number(chainId),
    verifyingContract: PERMIT2,
  };

  console.log("Domain:", domain);
  
  // 计算 DOMAIN_SEPARATOR
  const domainSeparator = ethers.TypedDataEncoder.hashDomain(domain);
  console.log("Calculated DOMAIN_SEPARATOR:", domainSeparator);
  
  // 从链上获取实际的 DOMAIN_SEPARATOR
  const permit2Contract = new ethers.Contract(
    PERMIT2,
    ["function DOMAIN_SEPARATOR() view returns (bytes32)"],
    provider
  );
  const onchainDomainSeparator = await permit2Contract.DOMAIN_SEPARATOR();
  console.log("Onchain DOMAIN_SEPARATOR:   ", onchainDomainSeparator);
  
  if (domainSeparator !== onchainDomainSeparator) {
    console.error("\n❌ ERROR: DOMAIN_SEPARATOR mismatch!");
    console.error("This will cause signature verification to fail.");
    process.exit(1);
  }
  console.log("✅ DOMAIN_SEPARATOR matches!\n");

  const types = {
    TokenPermissions: [
      { name: "token", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    PermitBatchTransferFrom: [
      { name: "permitted", type: "TokenPermissions[]" },
      { name: "spender", type: "address" },  // ✅ 添加 spender 字段
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  };

  // 构造 permitted 数组
  let permitted;
  if (MODE === "1") {
    permitted = [
      { token: TOKEN, amount: MAX_SINGLE_AMOUNT }
    ];
  } else {
    permitted = [
      { token: TOKEN, amount: MAX_VTOKEN_AMOUNT },
      { token: LINK,  amount: MAX_LINK_AMOUNT }
    ];
  }

  // spender 是实际调用 permitTransferFrom 的地址
  // 对于 Bridge.sendToken: spender = Bridge 合约地址
  // 对于直接测试: spender = 调用者的 EOA 地址
  const SPENDER = SPENDER_ARG || await signer.getAddress();
  
  console.log("Spender (who will call permitTransferFrom):", SPENDER);

  const message = {
    permitted,
    spender: SPENDER,  // ✅ 添加 spender
    nonce: NONCE,
    deadline: DEADLINE,
  };

  console.log("Signing typedData...");
  
  // 计算 message hash
  const messageHash = ethers.TypedDataEncoder.hash(domain, types, message);
  console.log("\nCalculated EIP-712 hash (should match Tenderly):");
  console.log(messageHash);
  
  const signature = await signer.signTypedData(domain, types, message);

  const permitInput = {
    permit: message,
    signature,
  };

  console.log("\n=== permitInput (paste into frontend) ===");
console.log(
  JSON.stringify(
    permitInput,
    (_, v) => (typeof v === "bigint" ? v.toString() : v),  // ➜ 解决 BigInt JSON 问题
    2
  )
);
;
}

main().catch(console.error);
