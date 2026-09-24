# Mermaid 图表测试文档


> 用 markdown 查看器打开本文件，验证 ```mermaid 代码块能正常渲染成图。
> 覆盖：流程图、时序图、类图、状态图、甘特图、饼图、旅行图、思维导图、时间线、象限图、需求图。

## 1. 流程图（flowchart TD）

```mermaid
flowchart TD
    classDef start fill:#FFF1B8,stroke:#F5B800,stroke-width:1.5px
    classDef process fill:#DDE9FF,stroke:#5287FF,stroke-width:1.5px
    classDef decision fill:#FFD9F0,stroke:#E83DB8,stroke-width:1.5px
    classDef document fill:#FFE0DC,stroke:#FF806D,stroke-width:1.5px
    class A,G start
    class B decision
    class C,E,F process
    class D document
    A[开始] --> B{是否已登录?}
    B -- 是 --> C[进入主页]
    B -- 否 --> D[跳转登录页]
    C --> E[请求数据]
    E --> F[渲染图表]
    F --> G[结束]
    class A,G start
    class B decision
    class C,E,F process
    class D document
```

## 2. 流程图（flowchart LR，带子图）

```mermaid
flowchart LR
    subgraph 前端
        A[UI 组件] --> B[状态管理]
    end
    subgraph 后端
        C[API 服务] --> D[数据库]
    end
    B --> C
```

## 3. 时序图（sequenceDiagram）

```mermaid
sequenceDiagram
    participant U as 用户
    participant S as 服务端
    participant DB as 数据库
    U->>S: 发送登录请求
    S->>DB: 查询用户
    DB-->>S: 返回用户信息
    S-->>U: 返回 token
    Note over S,DB: 校验密码
```

## 4. 类图（classDiagram）

```mermaid
classDiagram
    class Animal {
        +String name
        +int age
        +eat() void
    }
    class Dog {
        +bark() void
    }
    class Cat {
        +meow() void
    }
    Animal <|-- Dog
    Animal <|-- Cat
    Dog "1" --> "1" Owner
```

## 5. 状态图（stateDiagram-v2）

```mermaid
stateDiagram-v2
    [*] --> 待审核
    待审核 --> 已通过: 审核通过
    待审核 --> 已驳回: 审核驳回
    已通过 --> [*]
    已驳回 --> 待审核: 重新提交
```

## 6. 甘特图（gantt）

```mermaid
gantt
    title 项目排期
    dateFormat YYYY-MM-DD
    section 设计
    需求分析    :done,   a1, 2026-08-01, 3d
    UI 设计     :active, a2, 2026-08-04, 5d
    section 开发
    前端开发    :       a3, 2026-08-09, 7d
    后端开发    :       a4, 2026-08-09, 7d
```

## 7. 饼图（pie）

```mermaid
pie title 浏览器市场份额
    "Chrome"  : 62
    "Edge"    : 13
    "Firefox" : 5
    "Safari"  : 12
    "其他"    : 8
```

## 8. 旅行图（journey）

```mermaid
journey
    title 我的工作日
    section 上午
      起床: 3: 我
      通勤: 2: 我
      工作: 4: 我
    section 下午
      午休: 3: 我
      工作: 5: 我
```

## 9. 思维导图（mindmap）

```mermaid
mindmap
  root((项目))
    前端
      框架
      UI 库
    后端
      API
      数据库
    部署
      服务器
      CI/CD
```

## 10. 时间线（timeline）

```mermaid
timeline
    title 版本历史
    2024-06 : v1.0 发布
    2025-01 : v1.5 性能优化
    2026-08 : v2.0 图表支持
```

## 11. 象限图（quadrantChart）

```mermaid
quadrantChart
    title 功能优先级
    x-axis 低价值 --> 高价值
    y-axis 低复杂度 --> 高复杂度
    快速实现: [0.6, 0.4]
    核心功能: [0.8, 0.7]
    远期愿景: [0.2, 0.8]
    探索试验: [0.3, 0.2]
```

## 12. 需求图（requirementDiagram）

```mermaid
requirementDiagram
    requirement 登录功能 {
        id: 1
        text: 用户能够登录系统
        risk: high
        verifymethod: test
    }
    element 登录模块 {
        type: system
    }
    登录功能 - satisfies -> 登录模块
```

---

## 普通 markdown 元素（对照用）

- 普通列表项 A
- 普通列表项 B

| 列 1 | 列 2 |
|------|------|
| a    | b    |

```dart
void main() {
  print('这应该走普通代码块渲染');
}
```
