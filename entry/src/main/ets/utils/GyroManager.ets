import { sensor } from '@kit.SensorServiceKit';

export class GyroManager {
  private static instance: GyroManager | null = null;
  public callback: ((data: sensor.GyroscopeResponse) => void) | null = null;

  static getInstance(): GyroManager {
    if (!GyroManager.instance) {
      GyroManager.instance = new GyroManager();
    }
    return GyroManager.instance;
  }
}