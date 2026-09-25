import { register as upstreamRegister } from './vendor-winnow/winnow.ts'

export const register = (on: any, options: any) => upstreamRegister(on, options)
