#!/usr/bin/env python3
import json, pathlib
path = pathlib.Path("broadcast/DeployBurnMintPools.s.sol/11155111/run-latest.json")
data = json.loads(path.read_text())
TARGET = "0xfe81dbc7ec3ae383a7535f5afae817621f2f0e34"
for tx in data["transactions"]:
    if tx.get("contractAddress", "").lower() == TARGET:
        input_data = tx["transaction"]["input"]
        args = input_data[-2*448:]
        print("0x" + args.lower())
        break
