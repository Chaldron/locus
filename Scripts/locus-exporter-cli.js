#!/usr/bin/env node

const crypto = require("node:crypto");
const fs = require("node:fs/promises");
const path = require("node:path");

const API_ROOT = "https://api.apple-cloudkit.com";
const DEFAULT_CONTAINER_ID = "iCloud.com.adityasm.locus.v2";
const DEFAULT_ENVIRONMENT = "development";
const DEFAULT_RECORD_TYPE = "Track";
const RESULTS_LIMIT = 200;

function usage() {
  console.log(`Usage:
  node locus-exporter-cli.js \\
    --key-id YOUR_KEY_ID \\
    --private-key /path/to/eckey.pem \\
    --output-dir /path/to/output \\
    [--container-id ${DEFAULT_CONTAINER_ID}] \\
    [--environment development|production]

Requires Node.js 18+ for built-in fetch.`);
}

function parseArguments(argv) {
  const argumentsByName = {
    "--container-id": DEFAULT_CONTAINER_ID,
    "--environment": DEFAULT_ENVIRONMENT,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];

    if (argument === "--help" || argument === "-h") {
      usage();
      process.exit(0);
    }

    if (!argument.startsWith("--")) {
      throw new Error(`Unexpected argument: ${argument}`);
    }

    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for ${argument}`);
    }

    argumentsByName[argument] = value;
    index += 1;
  }

  if (!argumentsByName["--key-id"] || !argumentsByName["--private-key"] || !argumentsByName["--output-dir"]) {
    usage();
    throw new Error("Missing required arguments.");
  }

  if (!["development", "production"].includes(argumentsByName["--environment"])) {
    throw new Error(`Unsupported environment: ${argumentsByName["--environment"]}`);
  }

  return {
    keyID: argumentsByName["--key-id"],
    privateKeyPath: path.resolve(argumentsByName["--private-key"]),
    outputDirectory: path.resolve(argumentsByName["--output-dir"]),
    containerID: argumentsByName["--container-id"],
    environment: argumentsByName["--environment"],
  };
}

function iso8601Now() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function signPayload(message, privateKeyPEM) {
  return crypto.sign("sha256", Buffer.from(message, "utf8"), privateKeyPEM).toString("base64");
}

async function cloudKitPost(subpath, body, config) {
  if (typeof fetch !== "function") {
    throw new Error("This script requires Node.js 18+ because it uses the built-in fetch API.");
  }

  const bodyJSON = JSON.stringify(body);
  const dateString = iso8601Now();
  const bodyHash = crypto.createHash("sha256").update(bodyJSON).digest("base64");
  const signaturePayload = `${dateString}:${bodyHash}:${subpath}`;
  const signature = signPayload(signaturePayload, config.privateKeyPEM);

  const response = await fetch(`${API_ROOT}${subpath}`, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "X-Apple-CloudKit-Request-KeyID": config.keyID,
      "X-Apple-CloudKit-Request-ISO8601Date": dateString,
      "X-Apple-CloudKit-Request-SignatureV1": signature,
    },
    body: bodyJSON,
  });

  if (!response.ok) {
    throw new Error(`CloudKit request failed with HTTP ${response.status}: ${await response.text()}`);
  }

  return response.json();
}

async function queryRecords(config) {
  const subpath = `/database/1/${config.containerID}/${config.environment}/public/records/query`;
  const records = [];
  let continuationMarker = null;

  while (true) {
    const body = {
      query: {
        recordType: DEFAULT_RECORD_TYPE,
        filterBy: [],
      },
      desiredKeys: ["filename", "file"],
      resultsLimit: RESULTS_LIMIT,
    };

    if (continuationMarker !== null) {
      body.continuationMarker = continuationMarker;
    }

    const response = await cloudKitPost(subpath, body, config);

    if (response.serverErrorCode) {
      if (response.serverErrorCode === "BAD_REQUEST") {
        throw new Error("CloudKit rejected the public Track query. Ensure the public Track schema has a queryable index.");
      }

      throw new Error(`CloudKit query failed with ${response.serverErrorCode}: ${JSON.stringify(response)}`);
    }

    records.push(...(response.records || []));
    continuationMarker = response.continuationMarker || null;

    if (continuationMarker === null) {
      return records;
    }
  }
}

function outputFilename(record) {
  const recordName = record.recordName || "unknown-track";
  const filename = record.fields?.filename?.value || `${recordName}.gpx`;
  const sanitizedName = path.basename(filename);

  if (!sanitizedName) {
    throw new Error(`Record ${recordName} returned an empty filename.`);
  }

  return sanitizedName;
}

function assetDownloadURL(record, filename) {
  const recordName = record.recordName || "unknown-track";
  const downloadURL = record.fields?.file?.value?.downloadURL;

  if (!downloadURL) {
    throw new Error(`Record ${recordName} is missing the CloudKit asset download URL.`);
  }

  return downloadURL.replace("${f}", encodeURIComponent(filename));
}

async function downloadAsset(downloadURL, destinationPath) {
  const temporaryPath = path.join(path.dirname(destinationPath), `.${path.basename(destinationPath)}.part`);

  await fs.rm(temporaryPath, { force: true });

  try {
    const response = await fetch(downloadURL);
    if (!response.ok) {
      throw new Error(`Asset download failed with HTTP ${response.status}.`);
    }

    const assetBytes = Buffer.from(await response.arrayBuffer());
    await fs.writeFile(temporaryPath, assetBytes);
    await fs.rename(temporaryPath, destinationPath);
  } finally {
    await fs.rm(temporaryPath, { force: true });
  }
}

async function exportTracks(config) {
  await fs.mkdir(config.outputDirectory, { recursive: true });

  const records = await queryRecords(config);
  let failureCount = 0;

  console.log(`Found ${records.length} CloudKit track records.`);

  for (const record of records) {
    const recordName = record.recordName || "unknown-track";

    if (record.serverErrorCode) {
      failureCount += 1;
      console.error(`Failed to fetch record payload for ${recordName}: ${record.serverErrorCode}`);
      continue;
    }

    try {
      const filename = outputFilename(record);
      const downloadURL = assetDownloadURL(record, filename);
      const destinationPath = path.join(config.outputDirectory, filename);
      await downloadAsset(downloadURL, destinationPath);
      console.log(`Exported ${filename}`);
    } catch (error) {
      failureCount += 1;
      console.error(`Failed to export ${recordName}: ${error.message}`);
    }
  }

  if (failureCount === 0) {
    console.log(`Finished exporting ${records.length} tracks to ${config.outputDirectory}`);
    return;
  }

  process.exitCode = 1;
  console.error(
    `Finished exporting ${records.length - failureCount} tracks to ${config.outputDirectory}; ${failureCount} failed.`,
  );
}

async function main() {
  try {
    const argumentsByName = parseArguments(process.argv.slice(2));
    const privateKeyPEM = await fs.readFile(argumentsByName.privateKeyPath, "utf8");

    await exportTracks({
      ...argumentsByName,
      privateKeyPEM,
    });
  } catch (error) {
    process.exitCode = 1;
    console.error(error.message);
  }
}

void main();
