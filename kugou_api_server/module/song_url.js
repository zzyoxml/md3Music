const deviceConfig = require('../device_config');

module.exports = (params, useAxios) => {
  const hash = (params?.hash || '').toLowerCase();
  const isLite = process.env.platform === 'lite';
  const page_id = isLite ? 967177915 : 151369488;
  const ppage_id = isLite
    ? (params.ppage_id || '356753938,823673182,967485191')
    : '463467626,350369493,788954147';
  const quality = params.quality || 128;

  const deviceInfo = deviceConfig.getDeviceInfo();
  const dfid = (deviceInfo.dfid && deviceInfo.dfid !== '-')
    ? deviceInfo.dfid
    : (params?.dfid || params?.cookie?.dfid || '-');

  const mid = (deviceInfo.mid && deviceInfo.mid !== '-')
    ? deviceInfo.mid
    : (params?.mid || params?.cookie?.KUGOU_API_MID || '-');
  const uuid = (deviceInfo.uuid && deviceInfo.uuid !== '-')
    ? deviceInfo.uuid
    : (params?.uuid || params?.cookie?.uuid || '-');
  const guid = (deviceInfo.guid && deviceInfo.guid !== '-')
    ? deviceInfo.guid
    : (params?.guid || params?.cookie?.KUGOU_API_GUID || '-');

  return useAxios({
    url: '/v5/url',
    method: 'GET',
    params: {
      album_id: Number(params.album_id ?? 0),
      area_code: 1,
      hash: hash,
      ssa_flag: 'is_fromtrack',
      version: 11430,
      page_id,
      quality: quality,
      album_audio_id: Number(params.album_audio_id ?? 0),
      behavior: 'play',
      pid: isLite ? 411 : 2,
      cmd: 26,
      pidversion: 3001,
      IsFreePart: params?.free_part ? 1 : 0,
      ppage_id,
      cdnBackup: 1,
      module: '',
      clientver: 11430,
    },
    encryptType: 'android',
    headers: { 'x-router': 'trackercdn.kugou.com' },
    encryptKey: true,
    notSign: true,
    cookie: Object.assign({}, { 
      dfid: dfid,
      KUGOU_API_MID: mid,
      uuid: uuid,
      KUGOU_API_GUID: guid,
      KUGOU_API_DEV: deviceInfo.serverDev || params?.cookie?.KUGOU_API_DEV || '-',
      KUGOU_API_MAC: deviceInfo.mac || params?.cookie?.KUGOU_API_MAC || '-'
    }, params?.cookie),
  });
};
