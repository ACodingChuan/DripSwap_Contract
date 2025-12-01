import https from 'https';

const pairs = {
    "vBTC_vUSDT": "0x3C5F6694456F9CE35cfE0b459C16EFcA380C70ea",
    "vBTC_vDAI": "0x62b17eC4d1F4b274bF998D6BCD4570A9f8E45Fe9",
    "vBTC_vUSDC": "0xDae14E909Bb4B77a2c187721B877279967195893",
    "vBTC_vETH": "0xad00AB83a3Aaa3fE48E21dd738e82b6AAcD4eBbb",
    "vBTC_vLINK": "0x7A247E3F42f0fab514FD32c076E95Add5900a711",
    "vUSDT_vDAI": "0x63fF7b7974e5B1B9b944Ac0fa87f98Dbe5a2fa1d",
    "vUSDT_vUSDC": "0x5623e52a5f4cfd272028f129291b43BB42A29C6D",
    "vUSDT_vETH": "0x9e1E7211fddff362fb3289eCCD6e93B21284f980",
    "vUSDT_vLINK": "0x2855b9FeBE9C16617cE5A4a66F50838FdB806Ce7",
    "vDAI_vUSDC": "0x5208D3802D520CcD5dc4A00922c68c758D342807",
    "vDAI_vETH": "0x6bF8659Fe87a250Bcf40938021092726CBBE0ad9",
    "vDAI_vLINK": "0x1A23C7A16A1A2153460585982837957B5fE637CC",
    "vUSDC_vETH": "0x25dCcBF72A348dE92bDf646bFAAAf66ADC7225C7",
    "vUSDC_vLINK": "0x5FD66fb96090E0c780539A1E3A0eFfDe765b6b42",
    "vETH_vLINK": "0x4047EDdAa71f98700dC0f9Eb4e21c2427Ca4A427",
    "vSCR_vUSDC": "0x9AFD47452b1e67B57a47432D6713e480AdF17436",
    "vSCR_vUSDT": "0x1C91AE1283a9f9E2c84950c2553a99CEB65d2703",
    "vSCR_vETH": "0x330d612323C67f3Ce2FD72c7DE29DC92C4EA94eE"
};

const RPC_URL = "https://eth-sepolia.g.alchemy.com/v2/oSx-nhyQC8VLw_zJg-xPFjN8W5Ykr9RN";

function checkCode(name, address) {
    return new Promise((resolve, reject) => {
        const data = JSON.stringify({
            jsonrpc: "2.0",
            id: 1,
            method: "eth_getCode",
            params: [address, "latest"]
        });

        const options = {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': data.length
            }
        };

        const req = https.request(RPC_URL, options, (res) => {
            let body = '';
            res.on('data', (chunk) => body += chunk);
            res.on('end', () => {
                try {
                    const result = JSON.parse(body).result;
                    const exists = result && result !== '0x';
                    resolve({ name, address, exists });
                } catch (e) {
                    reject(e);
                }
            });
        });

        req.on('error', reject);
        req.write(data);
        req.end();
    });
}

async function run() {
    console.log("Checking pairs for contract code...");
    console.log("-----------------------------------");
    
    for (const [name, address] of Object.entries(pairs)) {
        try {
            const { exists } = await checkCode(name, address);
            if (!exists) {
                console.log(`❌ [ABSENT] ${name}: ${address}`);
            } else {
                console.log(`✅ [EXISTS] ${name}: ${address}`);
            }
        } catch (e) {
            console.error(`Error checking ${name}: ${e.message}`);
        }
        // Add a small delay to avoid rate limiting
        await new Promise(resolve => setTimeout(resolve, 200));
    }
}

run();
