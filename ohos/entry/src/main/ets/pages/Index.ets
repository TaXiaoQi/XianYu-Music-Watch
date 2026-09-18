
import { common } from '@kit.AbilityKit';
import { FlutterPage } from '@ohos/flutter_ohos'
import { dispatchBackToFlutter } from '../entryability/BackDispatcher'
import { dispatchCrownToFlutter } from '../entryability/RotaryDispatcher'

let storage = LocalStorage.getShared()

@Entry(storage)
@Component
struct Index {
  @LocalStorageLink('viewId') viewId: string = "";

  build() {
    Column() {
      FlutterPage({ viewId: this.viewId })
    }
    .onDigitalCrown((event: CrownEvent) => {
      // 表冠 → Flutter：只转发 UPDATE 的角度增量（BEGIN/END 无增量）。
      // onDigitalCrown 为 ArkUI 通用事件（API 18+），全页只有这里注册，
      // 命中即本回调、无冒泡重复派发。FlutterPage 内部是 XComponent 渲染，
      // 若真机测得事件被其吞掉不冒泡，把本回调改挂到 FlutterPage() 调用处。
      // 消息 = 带符号 degree（正=顺时针），Dart 侧按 度→像素(×2) 折算。
      if (event.action === CrownAction.UPDATE) {
        dispatchCrownToFlutter(event.degree)
      }
    })
  }

  onBackPress(): boolean {
    // back 的唯一可消费点（ability 级 onBackPressed 拦截不了）：转发给
    // Flutter（popRoute），二级页弹栈 / 根路由翻页 / 最左页退后台全部由
    // Dart 决策；返回 true 消费，绝不走系统默认退后台/销毁。
    dispatchBackToFlutter(getContext(this) as common.UIAbilityContext)
    return true
  }
}
