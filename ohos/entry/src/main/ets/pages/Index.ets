
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
    dispatchBackToFlutter(getContext(this) as common.UIAbilityContext)
    return true
  }
}
