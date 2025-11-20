import { ethers } from "ethers";

const domain = {
  name: "Permit2",
  chainId: 11155111,
  verifyingContract: "0x000000000022D473030F116dDEE9F6B43aC78BA3"
};

// 手动指定顺序
const domainOrdered = {
  name: domain.name,
  version: domain.version,
  chainId: domain.chainId,
  verifyingContract: domain.verifyingContract,
};

const sep = ethers.TypedDataEncoder.hashDomain(domainOrdered);
console.log(sep);

const types = {
  TokenPermissions: [
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
  ],
  PermitTransferFrom: [
    { name: "permitted", type: "TokenPermissions" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};

const permit = {
  permitted: {
    token: "0x779877A7B0D9E8603169DdbD7836e478b4624789",
    amount: "1000000000000000000",
  },
  nonce: 1,
  deadline: 1763188585,
};

const sig = "0x1e4e10c644a0ce1194c1286288b390a9bd23241079788ddedf6d51aa801c53db1c81db3f4afbf05a4ed4d5cdd04fc2df17452f92454c5376a38381cbec3a97561c";

// console.log(ethers.verifyTypedData(domain, types, permit, sig));
// const sepLocal = ethers.TypedDataEncoder.hashDomain(domain);
// console.log(sepLocal);