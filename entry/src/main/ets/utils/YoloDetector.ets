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

// 边界框接口
export interface BoundingBox {
  left: number;
  top: number;
  width: number;
  height: number;
}

// 给张雅萱用的输出结构
export interface DetectedObject {
  label: string;
  labelId: number;
  score: number;
  box: BoundingBox;
}

// MindSpore Lite 的 Context 配置接口（ArkTS 要求显式声明）
interface MsContext {
  target: string[];
  cpu: MsCpuConfig;
}

interface MsCpuConfig {
  threadNum: number;
  threadAffinityMode: number;
  precisionMode: string;
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

      // 用显式声明的接口，不能写对象字面量当类型
      const cpuConfig: MsCpuConfig = {
        threadNum: 4,
        threadAffinityMode: 1,
        precisionMode: 'enforce_fp32'
      };

      const msContext: MsContext = {
        target: ['nnrt', 'cpu'],
        cpu: cpuConfig
      };

      this.model = await mindSporeLite.loadModelFromBuffer(
        modelBuffer,
        msContext as mindSporeLite.Context
      );
      hilog.info(0xFF00, 'YoloDetector', '模型加载成功');
      return true;
    } catch (error) {
      hilog.error(0xFF00, 'YoloDetector', `模型加载失败: ${JSON.stringify(error)}`);
      return false;
    }
  }

  async detect(inputBuffer: Float32Array): Promise<DetectedObject[]> {
    if (this.model === null) {
      hilog.error(0xFF00, 'YoloDetector', '模型未加载');
      return [];
    }

    try {
      const modelInputs: mindSporeLite.MSTensor[] = this.model.getInputs();
      hilog.info(0xFF00, 'YoloDetector', `输入张量数量: ${modelInputs.length}`);

      if (modelInputs.length === 0) {
        hilog.error(0xFF00, 'YoloDetector', 'getInputs 返回空');
        return [];
      }

      const inputTensor = modelInputs[0];
      hilog.info(0xFF00, 'YoloDetector',
        `输入 shape: ${JSON.stringify(inputTensor.shape)}, ` +
          `dtype: ${inputTensor.dataType}, ` +
          `数据长度: ${inputBuffer.length}`);

      inputTensor.setData(inputBuffer.buffer);
      hilog.info(0xFF00, 'YoloDetector', 'setData 成功，开始 predict');

      const outputs: mindSporeLite.MSTensor[] = await this.model.predict(modelInputs);
      hilog.info(0xFF00, 'YoloDetector', `predict 成功，输出数量: ${outputs.length}`);

      return this.parseOutput(outputs);
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(0xFF00, 'YoloDetector',
        `推理失败: code=${e.code}, message=${e.message}`);
      return [];
    }
  }

  private parseOutput(outputs: mindSporeLite.MSTensor[]): DetectedObject[] {
    if (outputs.length === 0) return [];

    const outputData = new Float32Array(outputs[0].getData());
    const results: DetectedObject[] = [];

    const numBoxes = 25200;
    const valuesPerBox = 85;

    for (let i = 0; i < numBoxes; i++) {
      const offset = i * valuesPerBox;

      const confidence = outputData[offset + 4];
      if (confidence < 0.5) continue;

      let maxClassScore = 0;
      let maxClassId = -1;
      for (let c = 0; c < 80; c++) {
        const classScore = outputData[offset + 5 + c];
        if (classScore > maxClassScore) {
          maxClassScore = classScore;
          maxClassId = c;
        }
      }

      const finalScore = confidence * maxClassScore;
      if (finalScore < 0.5) continue;

      const cx = outputData[offset + 0] / this.INPUT_SIZE;
      const cy = outputData[offset + 1] / this.INPUT_SIZE;
      const w = outputData[offset + 2] / this.INPUT_SIZE;
      const h = outputData[offset + 3] / this.INPUT_SIZE;

      const box: BoundingBox = {
        left: cx - w / 2,
        top: cy - h / 2,
        width: w,
        height: h
      };

      results.push({
        label: COCO_LABELS[maxClassId] || `物体${maxClassId}`,
        labelId: maxClassId,
        score: finalScore,
        box: box
      });
    }

    return results.sort((a, b) => b.score - a.score);
  }

  release(): void {
    if (this.model !== null) {
      this.model = null;
      hilog.info(0xFF00, 'YoloDetector', '模型已释放');
    }
  }
}