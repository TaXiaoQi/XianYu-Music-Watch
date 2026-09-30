
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
      if (event.action === CrownAction.UPDATE) {
        dispatchCrownToFlutter(event.degree)
      }
    })
  }

  onBackPress(): boolean {
    // getContext 已弃用（API 18），组件内用 UIContext 取宿主 Context
    dispatchBackToFlutter(this.getUIContext().getHostContext() as common.UIAbilityContext)
    return true
  }
}
