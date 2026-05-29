const { cryptoMd5 } = require('./util/crypto');
const { getGuid, calculateMid, randomString } = require('./util/util');

let dfid = null;
let mid = null;
let uuid = null;
let guid = null;
let serverDev = null;
let mac = null;

function initDeviceInfo() {
  if (!guid) {
    guid = getGuid();
  }
  if (!mid) {
    mid = calculateMid(guid);
  }
  if (!uuid) {
    uuid = dfid ? cryptoMd5(`${dfid}${mid}`) : '-';
  }
  if (!serverDev) {
    serverDev = randomString(10).toUpperCase();
  }
  if (!mac) {
    mac = '02:00:00:00:00:00';
  }
}

function setDfid(newDfid) {
  dfid = newDfid;
  if (mid) {
    uuid = cryptoMd5(`${dfid}${mid}`);
  }
}

function setMid(newMid) {
  mid = newMid;
  if (dfid) {
    uuid = cryptoMd5(`${dfid}${mid}`);
  }
}

function getDeviceInfo() {
  initDeviceInfo();
  return {
    dfid: dfid || '-',
    mid: mid || '-',
    uuid: uuid || '-',
    guid: guid || '-',
    serverDev: serverDev || '-',
    mac: mac || '-'
  };
}

module.exports = {
  getDfid: () => dfid,
  setDfid,
  getMid: () => mid,
  setMid,
  getUuid: () => {
    initDeviceInfo();
    return uuid;
  },
  getGuid: () => {
    initDeviceInfo();
    return guid;
  },
  getServerDev: () => {
    initDeviceInfo();
    return serverDev;
  },
  getMac: () => {
    initDeviceInfo();
    return mac;
  },
  getDeviceInfo,
  initDeviceInfo
};
