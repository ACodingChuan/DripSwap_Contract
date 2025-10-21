#!/usr/bin/env node

/**
 * 从 Foundry 编译产物中提取 ABI 到 ./abi 目录
 * 会在运行前清空旧的 ABI 文件。
 */

const fs = require("fs");
const path = require("path");

console.log("🔄 开始提取 ABI 文件到 ./abi 目录...");

const projectRoot = process.cwd();
const abiDir = path.join(projectRoot, "abi");
const outDir = path.join(projectRoot, "out");

if (!fs.existsSync(outDir)) {
  console.error("❌ 未找到 out 目录，请先执行 forge build。");
  process.exit(1);
}

// 确保 abi 目录存在
fs.mkdirSync(abiDir, { recursive: true });

// 不删除旧 ABI 文件，只做复制粘贴处理
console.log("📋 保留现有 ABI 文件，只更新或添加新文件...");

let count = 0;

function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "build-info") {
        continue;
      }
      walk(fullPath);
    } else if (entry.isFile() && entry.name.endsWith(".json")) {
      try {
        const content = JSON.parse(fs.readFileSync(fullPath, "utf8"));
        if (Array.isArray(content.abi)) {
          const filename = path.basename(entry.name, ".json");
          const target = path.join(abiDir, `${filename}.json`);
          
          // 检查文件是否已存在
          if (fs.existsSync(target)) {
            console.log(`📋 更新: ${filename}.json`);
          } else {
            console.log(`✅ 新增: ${filename}.json`);
          }
          
          fs.writeFileSync(target, JSON.stringify(content.abi, null, 2));
          count += 1;
        }
      } catch (err) {
        console.warn(`⚠️ 跳过无效 JSON 文件: ${entry.name}`);
      }
    }
  }
}

walk(outDir);

console.log(`🎉 ABI 提取完成，共处理 ${count} 个文件。`);
