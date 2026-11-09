| 通道 | 模板 | 关键机制 | 证据 |
|:---|:---|:---|:---|
| 一 Stack 属性引用 | producer + consumer-ref | Export + Fn::ImportValue | producer 导出 2 项 / ref 模板 ImportValue ×1 |
| 二 NestedStack | parent（+ 独立 .nested 子模板） | Fn::GetAtt [嵌套资源, Outputs.X] | 嵌套资源 1 个，GetAtt×2 |
| 三 SSM 运行时 | consumer-ssm | IaC 只传参数名，运行时 get_parameter | ref 值出现 1 次（仅参数名，无 URL） |
