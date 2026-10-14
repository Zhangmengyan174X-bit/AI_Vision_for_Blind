// utils/YoloDetector.ets
import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

// COCO 80类标签
const COCO_LABELS: string[] = [
  '人', '自行车', '汽车', '摩托车', '飞机', '公交车', '火车', '卡车', '船',
  '红绿灯', '消防栓', '停止标志', '停车计时器', '长椅', '鸟', '猫', '狗',
  '马', '羊', '牛', '大象', '熊', '斑马', '长颈鹿', '背包', '雨伞',
  '手提包', '领带', '行李箱', '飞盘', '滑雪板', '单板滑雪', '运动球',
  '风筝', '棒球棒', '棒球手套', '滑板', '冲浪板', '网球拍', '瓶子',
  '红酒杯', '杯子', '叉子', '刀', '勺子', '碗', '香蕉', '苹果',
  '三明治', '橙子', '西兰花', '胡萝卜', '热狗', '披萨', '甜甜圈',
  '蛋糕', '椅子', '沙发', '盆栽', '床', '餐桌', '马桶', '电视',
  '笔记本电脑', '鼠标', '遥控器', '键盘', '手机', '微波炉', '烤箱',
  '烤面包机', '水槽', '冰箱', '书', '时钟', '花瓶', '剪刀', '泰迪熊',
  '吹风机', '牙刷'
];

export interface BoundingBox {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface DetectedObject {
  label: string;
  labelId: number;
  score: number;
  box: BoundingBox;
}

export class YoloDetector {
  private model: mindSporeLite.Model | null = null;
  private context: common.UIAbilityContext;
  private readonly MODEL_NAME: string = 'yolov8n.ms';
  private readonly INPUT_SIZE: number = 640;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async loadModel(): Promise<boolean> {
    try {
      const rawFileContent: Uint8Array =
        await this.context.resourceManager.getRawFileContent(this.MODEL_NAME);
      const modelBuffer: ArrayBuffer = rawFileContent.buffer as ArrayBuffer;

      // CPU 配置（官方类型 CpuDevice）
      const cpuConfig: mindSporeLite.CpuDevice = {
        threadNum: 4,
        threadAffinityMode: mindSporeLite.ThreadAffinityMode.BIG_CORES_FIRST,
        precisionMode: 'enforce_fp32'
      };

      // 枚举 NNRT 设备，找加速器（NPU）
      let nnrtDeviceID: bigint | undefined = undefined;
      let nnrtName: string = '';
      try {
        const devices = mindSporeLite.getAllNNRTDeviceDescriptions();
        hilog.info(0xFF00, 'YoloDetector', `[NNRT] 枚举到 ${devices.length} 个设备`);
        for (let i = 0; i < devices.length; i++) {
          const d = devices[i];
          const idStr: string = d.deviceID().toString();
          const typeStr: string = d.deviceType().toString();
          const nameStr: string = d.deviceName();
          hilog.info(0xFF00, 'YoloDetector',
            `[NNRT] id=${idStr}, type=${typeStr}, name=${nameStr}`);

          if (d.deviceType() === mindSporeLite.NNRTDeviceType.NNRTDEVICE_ACCELERATOR
            && nnrtDeviceID === undefined) {
            nnrtDeviceID = d.deviceID();
            nnrtName = nameStr;
          }
        }
      } catch (err) {
        const e = err as BusinessError;
        hilog.error(0xFF00, 'YoloDetector',
          `[NNRT] 枚举失败: code=${e.code}, message=${e.message}`);
      }

      // 组装 MsContext
      let msContext: mindSporeLite.Context;
      if (nnrtDeviceID !== undefined) {
        msContext = {
          target: ['nnrt', 'cpu'],
          cpu: cpuConfig,
          nnrt: {
            deviceID: nnrtDeviceID,
            performanceMode: mindSporeLite.PerformanceMode.PERFORMANCE_HIGH,
            priority: mindSporeLite.Priority.PRIORITY_HIGH
          }
        };
        hilog.info(0xFF00, 'YoloDetector',
          `[NNRT] 使用 NPU + CPU 混合推理, device=${nnrtName}`);
      } else {
        msContext = {
          target: ['cpu'],
          cpu: cpuConfig
        };
        hilog.warn(0xFF00, 'YoloDetector', '[NNRT] 未发现加速器，回退纯 CPU');
      }

      this.model = await mindSporeLite.loadModelFromBuffer(modelBuffer, msContext);
      hilog.info(0xFF00, 'YoloDetector', '模型加载成功');
      return true;
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(0xFF00, 'YoloDetector',
        `模型加载失败: code=${e.code}, message=${e.message}`);
      return false;
    }
  }

  async detect(inputBuffer: Float32Array): Promise<DetectedObject[]> {
    hilog.info(0xFF00, 'YoloDetector', '=== detect 进入 ===');

    if (this.model === null) {
      hilog.error(0xFF00, 'YoloDetector', '模型未加载');
      return [];
    }

    if (!inputBuffer) {
      hilog.error(0xFF00, 'YoloDetector', 'inputBuffer 为 undefined');
      return [];
    }
    hilog.info(0xFF00, 'YoloDetector', `输入数据长度: ${inputBuffer.length}`);

    try {
      hilog.info(0xFF00, 'YoloDetector', '准备调用 getInputs');
      const modelInputs: mindSporeLite.MSTensor[] = this.model.getInputs();

      if (!modelInputs) {
        hilog.error(0xFF00, 'YoloDetector', 'getInputs 返回 undefined');
        return [];
      }
      hilog.info(0xFF00, 'YoloDetector', `输入张量数量: ${modelInputs.length}`);

      if (modelInputs.length === 0) {
        hilog.error(0xFF00, 'YoloDetector', 'getInputs 返回空数组');
        return [];
      }

      const inputTensor = modelInputs[0];
      if (!inputTensor) {
        hilog.error(0xFF00, 'YoloDetector', 'modelInputs[0] 为 undefined');
        return [];
      }

      hilog.info(0xFF00, 'YoloDetector', '准备 setData');
      inputTensor.setData(inputBuffer.buffer);
      hilog.info(0xFF00, 'YoloDetector', 'setData 成功，准备 predict');

      const outputs: mindSporeLite.MSTensor[] = await this.model.predict(modelInputs);

      if (!outputs) {
        hilog.error(0xFF00, 'YoloDetector', 'predict 返回 undefined');
        return [];
      }
      hilog.info(0xFF00, 'YoloDetector', `predict 成功，输出数量: ${outputs.length}`);

      if (outputs.length === 0) {
        hilog.error(0xFF00, 'YoloDetector', '输出为空');
        return [];
      }

      return this.parseOutput(outputs);
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(0xFF00, 'YoloDetector',
        `推理失败: code=${e.code}, message=${e.message}`);
      return [];
    }
  }

  /**
   * YOLOv8 输出格式：[1, 84, 8400]
   * 84 = 4 坐标 + 80 类别，没有单独置信度
   * 注意：数据是转置的，按列访问
   */
  private parseOutput(outputs: mindSporeLite.MSTensor[]): DetectedObject[] {
    if (!outputs || outputs.length === 0) return [];

    const rawData = outputs[0].getData();
    if (!rawData) {
      hilog.error(0xFF00, 'YoloDetector', 'getData 返回 undefined');
      return [];
    }

    const outputData = new Float32Array(rawData);
    hilog.info(0xFF00, 'YoloDetector', `输出数据长度: ${outputData.length}`);

    const results: DetectedObject[] = [];
    const numClasses = 80;
    const numBoxes = 8400;

    for (let i = 0; i < numBoxes; i++) {
      // YOLOv8: 第 4 行是类别置信度最大的那个
      let maxClassScore = 0;
      let maxClassId = -1;
      for (let c = 0; c < numClasses; c++) {
        const classScore = outputData[(4 + c) * numBoxes + i];
        if (classScore > maxClassScore) {
          maxClassScore = classScore;
          maxClassId = c;
        }
      }

      if (maxClassScore < 0.5) continue;

      const cx = outputData[0 * numBoxes + i] / this.INPUT_SIZE;
      const cy = outputData[1 * numBoxes + i] / this.INPUT_SIZE;
      const w = outputData[2 * numBoxes + i] / this.INPUT_SIZE;
      const h = outputData[3 * numBoxes + i] / this.INPUT_SIZE;

      const box: BoundingBox = {
        left: cx - w / 2,
        top: cy - h / 2,
        width: w,
        height: h
      };

      results.push({
        label: COCO_LABELS[maxClassId] || `物体${maxClassId}`,
        labelId: maxClassId,
        score: maxClassScore,
        box: box
      });
    }

    hilog.info(0xFF00, 'YoloDetector', `解析出 ${results.length} 个目标`);
    return results.sort((a, b) => b.score - a.score);
  }

  release(): void {
    if (this.model !== null) {
      this.model = null;
      hilog.info(0xFF00, 'YoloDetector', '模型已释放');
    }
  }
}