// Only Pod 0 seeds a new set; existing configurations are never force-replaced.
const setName = process.env.MONGODB_REPLICA_SET;
const service = process.env.MONGODB_HEADLESS_FQDN;
const username = process.env.MONGODB_ROOT_USERNAME;
const password = process.env.MONGODB_ROOT_PASSWORD;
const appUsername = process.env.MONGO_APP_USERNAME;
const appPassword = process.env.MONGO_APP_PASSWORD;
const appDatabase = process.env.MONGO_APP_DATABASE;
if (!setName || !service || !username || !password || !appUsername || !appPassword || !appDatabase) {
  throw new Error("Bootstrap environment is incomplete");
}
const hosts = [0, 1, 2].map(i => `mongodb-${i}.${service}:27017`);

class ConfigurationError extends Error {}

async function connect(host) {
  const connection = await new Mongo(`mongodb://${host}/admin?directConnection=true&serverSelectionTimeoutMS=3000&connectTimeoutMS=3000`);
  const admin = await connection.getDB("admin");
  const authenticated = await admin.auth(username, password);
  if (authenticated !== 1 && authenticated?.ok !== 1) throw new Error("Root authentication failed");
  return admin;
}

function checked(result, operation) {
  if (result.ok !== 1 || result.writeConcernError) throw new Error(`${operation} failed, code=${result.code ?? "unknown"}`);
  return result;
}

async function getConfig(admin) {
  try {
    return await admin.runCommand({replSetGetConfig: 1});
  } catch (error) {
    // Await inside try so rejected commands are caught before returning.
    if (error.code === 94) return {ok: 0, code: 94};
    throw error;
  }
}

function validate(config) {
  if (config._id !== setName || !Array.isArray(config.members) || config.members.length > 3 || config.members.length === 0) {
    throw new ConfigurationError("Unexpected replica set name or member count");
  }
  for (const member of config.members) {
    if (!hosts.includes(member.host) || member._id !== hosts.indexOf(member.host) ||
        member.arbiterOnly || member.hidden || member.buildIndexes === false ||
        member.votes !== 1 || member.priority <= 0) {
      throw new ConfigurationError("Unexpected member configuration; manual review required");
    }
  }
  if (new Set(config.members.map(member => member.host)).size !== config.members.length) {
    throw new ConfigurationError("Duplicate replica set members");
  }
}

async function primary() {
  for (const host of hosts) {
    let admin;
    try {
      admin = await connect(host);
      const hello = checked(await admin.runCommand({hello: 1}), "hello");
      if (hello.setName && hello.setName !== setName) throw new ConfigurationError("Unexpected replica set name");
      if (hello.isWritablePrimary) return admin;
    } catch (error) {
      if (error instanceof ConfigurationError) throw error;
    }
  }
  throw new Error("Primary is not available yet");
}

async function ensureApplicationUser(leader) {
  const existing = checked(await leader.runCommand({
    usersInfo: {user: appUsername, db: appDatabase}, showCredentials: false
  }), "getAppUser").users;
  if (existing.length === 0) {
    const application = await leader.getSiblingDB(appDatabase);
    checked(await application.runCommand({
      createUser: appUsername,
      pwd: appPassword,
      roles: [{role: "readWrite", db: appDatabase}],
      writeConcern: {w: "majority", wtimeout: 10000}
    }), "createAppUser");
    print("Missing application account created with readWrite role");
  } else if (existing.length !== 1 || existing[0].roles.length !== 1 ||
      existing[0].roles[0].role !== "readWrite" || existing[0].roles[0].db !== appDatabase) {
    throw new ConfigurationError("Unexpected application roles; manual review required");
  }
  // Existing users are never password-rotated. Check the Secret on every member.
  for (const host of hosts) {
    const connection = await new Mongo(`mongodb://${host}/${appDatabase}?directConnection=true&serverSelectionTimeoutMS=3000&connectTimeoutMS=3000`);
    const application = await connection.getDB(appDatabase);
    const authenticated = await application.auth(appUsername, appPassword);
    if (authenticated !== 1 && authenticated?.ok !== 1) throw new Error("Application authentication failed");
    checked(await application.runCommand({connectionStatus: 1}), "appAuthentication");
  }
}

// --file runs as a script; keep await inside an async function.
(async function bootstrap() {
  let complete = false;
  for (let attempt = 1; attempt <= 120; attempt++) {
    let stage = "seed connection";
    try {
      const seed = await connect(hosts[0]);
      stage = "seed configuration";
      const existing = await getConfig(seed);
      if (existing.ok === 1) {
        validate(existing.config);
      } else if (existing.code === 94) {
        for (const host of hosts.slice(1)) {
          stage = "peer configuration";
          const peer = await getConfig(await connect(host));
          if (peer.ok === 1) throw new ConfigurationError("Seed is uninitialized but another member already has a configuration");
          if (peer.code !== 94) checked(peer, "checkPeerConfig");
        }
        // Seed alone first to keep a deterministic initial data source.
        stage = "seed initialization";
        checked(await seed.runCommand({replSetInitiate: {_id: setName, members: [{_id: 0, host: hosts[0]}]}}), "initiate");
      } else {
        checked(existing, "getConfig");
      }

      stage = "primary discovery";
      const leader = await primary();
      stage = "primary configuration";
      const config = checked(await getConfig(leader), "getConfig").config;
      validate(config);
      const missing = hosts.find(host => !config.members.some(member => member.host === host));
      if (missing) {
        stage = "member readiness";
        const current = checked(await leader.runCommand({replSetGetStatus: 1}), "getStatus");
        if (!current.members.every(member => member.health === 1 && [1, 2].includes(member.state))) {
          throw new Error("Existing members are still synchronizing");
        }
        config.version++;
        config.members.push({_id: hosts.indexOf(missing), host: missing, votes: 1, priority: 1});
        // One voting member at a time; never use force during membership changes.
        stage = "member addition";
        checked(await leader.runCommand({replSetReconfig: config, maxTimeMS: 10000}), "addMember");
      } else {
        stage = "final readiness";
        const status = checked(await leader.runCommand({replSetGetStatus: 1}), "getStatus");
        if (status.members.length === 3 && status.members.every(member =>
            hosts.includes(member.name) && member.health === 1 && [1, 2].includes(member.state)) &&
            status.members.filter(member => member.state === 1).length === 1) {
          stage = "application account and authentication";
          await ensureApplicationUser(leader);
          print("Replica Set ready: one PRIMARY and two SECONDARY; application authentication verified on all members");
          complete = true;
          break;
        }
      }
    } catch (error) {
      if (error instanceof ConfigurationError) throw error;
      // Report only fixed stage names and numeric codes, never raw connection errors.
      const code = Number.isInteger(error.code) ? error.code : "unavailable";
      print(`Waiting for Replica Set readiness, attempt ${attempt}/120, stage=${stage}, code=${code}`);
    }
    await sleep(5000);
  }
  if (!complete) throw new Error("Replica Set bootstrap timed out; inspect pods without deleting PVCs");
})().catch(error => {
  const code = Number.isInteger(error.code) ? error.code : "unavailable";
  const reason = error instanceof ConfigurationError
    ? error.message
    : "Bootstrap failed; inspect stage/code logs without deleting PVCs";
  print(`${reason}, code=${code}`);
  quit(1);
});
