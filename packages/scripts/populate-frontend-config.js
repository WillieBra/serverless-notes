const { spawnSync } = require("child_process");
const { join, resolve } = require("path");
const { readFileSync, writeFileSync, unlinkSync } = require("fs");

const isLocal = process.argv.includes("--local");
const isDev = process.argv.includes("--dev");
const outputsIndex = process.argv.indexOf("--outputs-file");
const suppliedOutputs = outputsIndex !== -1;
if (suppliedOutputs && !process.argv[outputsIndex + 1]) {
  console.error("--outputs-file requires a file path.");
  process.exit(1);
}
const cdkOutputsFile = suppliedOutputs
  ? resolve(process.argv[outputsIndex + 1])
  : join(__dirname, `tmp.${process.pid}.json`);
const configFile = join(__dirname, "..", "frontend", ".env");

try {
  if (!suppliedOutputs) {
    const result = spawnSync(
      process.execPath,
      [
        join(__dirname, "..", "..", ".yarn", "releases", "yarn-3.3.1.cjs"),
        isLocal ? "cdklocal" : "cdk",
        "deploy",
        "--outputs-file",
        cdkOutputsFile,
      ],
      { cwd: join(__dirname, "..", ".."), stdio: "inherit" }
    );
    if (result.error) throw result.error;
    if (result.status !== 0)
      throw new Error("Infrastructure deployment failed.");
  }

  const outputs = JSON.parse(readFileSync(cdkOutputsFile, "utf8"))[
    "aws-sdk-js-notes-app"
  ];
  for (const key of [
    "FilesBucket",
    "GatewayId",
    "IdentityPoolId",
    "Region",
    "FrontendDistributionId",
  ]) {
    if (!outputs?.[key]) throw new Error(`Missing CDK output: ${key}`);
  }
  const lines = [
    `VITE_FILES_BUCKET=${outputs.FilesBucket}`,
    `VITE_GATEWAY_ID=${outputs.GatewayId}`,
    `VITE_IDENTITY_POOL_ID=${outputs.IdentityPoolId}`,
    `VITE_REGION=${outputs.Region}`,
    `VITE_BASE_URL=${
      isDev ? "/" : `/cloudfront/${outputs.FrontendDistributionId}/`
    }`,
  ];
  if (isLocal) {
    lines.push(
      "VITE_LOCALSTACK_ENDPOINT=http://localhost:4566",
      `VITE_GATEWAY_URL=http://localhost:4566/restapis/${outputs.GatewayId}/prod/_user_request_/`
    );
  }
  writeFileSync(configFile, `${lines.join("\n")}\n`);
  console.log("Frontend configuration written to packages/frontend/.env");
} catch (error) {
  console.error(`Frontend configuration failed: ${error.message}`);
  process.exitCode = 1;
} finally {
  if (!suppliedOutputs) {
    try {
      unlinkSync(cdkOutputsFile);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
}
