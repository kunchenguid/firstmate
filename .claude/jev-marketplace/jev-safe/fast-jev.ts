import { register as upstreamRegister } from './vendor-fast/hooks/fast-jev.ts'

export const register = (on: any, options: any) => upstreamRegister(on, options)
