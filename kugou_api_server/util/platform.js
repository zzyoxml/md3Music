// 平台协议判断：强制走概念版（lite）协议
// 无论 cookie / 环境变量怎么设置，始终返回 true

const isPlatformLite = (_cookie) => true;

module.exports = {
  isPlatformLite,
};
