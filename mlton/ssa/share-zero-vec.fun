(* Copyright (C) 2017 Matthew Fluet.
 *
 * MLton is released under a BSD-style license.
 * See the file MLton-LICENSE for details.
 *)

functor ShareZeroVec (S: SSA_TRANSFORM_STRUCTS): SSA_TRANSFORM =
  struct

    open S
    open Exp

    (* split a list of statements at the point where the test var is declared;
     * return (pre, post, match)
     *)
    infix isIn;
    fun x isIn xs =
      case xs of
          []    => false
        | y::ys => if Var.equals (x, y) then true else x isIn ys

    fun split ((x as Statement.T {var, ...})::xs, arrayVars, pre) =
          if isSome var andalso (valOf var) isIn arrayVars
          then (List.rev pre, xs, SOME x)
          else split (xs, arrayVars, x::pre)
      | split ([], _, pre) = (List.rev pre, [], NONE)


    fun transform (Program.T {datatypes, globals, functions, main}) =
      let
        val functions' =
          List.revMap
          (functions, fn f =>
            let
              val {args, blocks, mayInline, name, raises, returns, start} =
                  Function.dest f

              (* 1st pass: compile a list of array vars to be frozen to vectors *)
              val funArrays =
                Vector.foldr
                (blocks,
                [],
                (fn (block as Block.T {statements, ...}, acc) =>
                  let
                    val blockArrays =
                      Vector.foldr
                      (statements,
                      [],
                      (fn (statement as Statement.T {exp, ...}, acc') =>
                        case exp of
                          PrimApp ({prim, args, ...}) =>
                            let
                              fun arg () = Vector.first args
                            in
                              case Prim.name prim of
                                  Array_toVector =>
                                    (arg ()) :: acc'
                                | _ => acc'
                            end
                        | _ => acc'))
                  in
                    blockArrays @ acc
                  end))

              (* TODO: 2nd iteration: new branching/merging *)
              (* mostly pseudocode for now *)
              val blocks =
                let
                  val blocks' = Vector.toList blocks
                  fun splitAndMerge
                      (block as Block.T {label, args, statements, transfer}::bs,
                       acc) =
                        let
                          val (pre, post, match) =
                            split ((Vector.toList statements), funArrays, [])
                        in
                          if isSome match
                          then
                            let
                              val n = (* test var *)
                                case (valOf match) of
                                    Statement.T {var, exp, ...}
                                      case exp of
                                        PrimApp ({prim, args, ...}) =>
                                          let
                                            fun arg () = Vector.first args
                                          in
                                              case Prim.name prim of
                                                Array_uninit => SOME (arg ())
                                            | _ => NONE
                                          end
                                  | _ => NONE

                              (* TODO: prepare cases and default label *)

                              val preBlock =
                                let
                                  sts = Vector.fromList pre
                                  transfer' = Case.T {test = n,
                                                      cases = ...,
                                                      default = ...}
                                in
                                  Block.T {label = label,
                                           args = args,
                                           statements = sts,
                                           transfer = transfer'}
                                end

                              val ifZeroBlock = ...
                              val ifNonzeroBlock = ...
                              val postBlock = ...
                            in
                              splitAndMerge
                                (postBlock::bs,
                                  preBlock::ifZeroBlock::ifNonzeroBlock::acc)
                            end
                          else splitAndMerge (bs, block::acc)
                        end

                    | splitAndMerge ([], acc) = acc
                in
                  splitAndMerge (blocks', [])
                end


              val blocks = Vector.fromList blocks


            in
              Function.new {args = args,
                            blocks = blocks,
                            mayInline = mayInline,
                            name = name,
                            raises = raises,
                            returns = returns,
                            start = start}
            end)

      in
          Program.T {datatypes = datatypes,
                    globals = globals,
                    functions = functions',
                    main = main}
      end

  end
