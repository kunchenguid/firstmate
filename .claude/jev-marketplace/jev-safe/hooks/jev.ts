import { register as fastRegister } from '../fast-jev.ts'
import { register as winnowRegister } from '../winnow.ts'

export const register = (on: any, options: any) => {
  fastRegister(on, options)
  winnowRegister(on, options)
}
