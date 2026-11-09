## ho09 部署链路解剖（全部本机实测）

1. synth：App 构造树 → cdk.out（模板 + 资产目录 asset.<散列>/ + manifest）。
2. 资产：Code.from_asset 打包 zip，对象名 = 内容散列 *。
3. bootstrap：CDKToolkit 栈建出 staging 桶（cdk-hnb659fds-assets-000000000000-us-east-1）与部署角色；
   未 bootstrap 时资产无法上传（cdk/01 教训）。
4. cdk deploy：CLI 上传资产 → 填模板 AssetParameters（桶/版本键/散列）→
   交给 CFN。模板里的 S3Bucket/S3Key 全是 Parameters——这就是 CLI 与
   CFN 的接口契约。
5. 手工通道：同一份模板，变更集三步（create→describe 审阅→execute），
   资产参数亲手填，照样部署成功且 Lambda 可用——CDK 产出即普通 CFN 模板。
