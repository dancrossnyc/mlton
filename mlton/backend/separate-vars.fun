(* Copyright (C) 2019 Jason Carr
 *
 * MLton is released under a HPND-style license.
 * See the file MLton-LICENSE for details.
 *
 * This pass copies some variables into new locations
 * so that the relatively naïve AllocateVars can give one location
 * to each variable.
 *
 * Although this is pretty tightly coupled to the AllocateVars, it saves
 * us a lot of complexity in both, since the latter does not need to do any
 * contortions to try to return multiple variables
 *
 * Mechanically, what we do is find the loops in the program, and try our best
 * to split up variables so that no variable that would have to be on the
 * stack appears in any loop. So while we might end up with some extra copies,
 * by construction we don't really do so in any loop where we wouldn't have to
 * already do something similar in practice.
 *
 * This must be run before implement-handlers, as it uses restore
 *)

functor SeparateVars(S: RSSA_TRANSFORM_STRUCTS): RSSA_TRANSFORM = 
struct

open S
open Rssa
structure Live = Live (Rssa)
structure Restore = RestoreR (Rssa)

fun shouldAvoid (Block.T {kind, ...}) =
   (* this definition is important;
    * we assume that no edge has even
    * one side inside a loop;
    * this is true because calls etc
    * must be unconditional;
    * i.e. not be able to get back
    * into the loop without necessarily
    * going over a bad edge *)
   case kind of
        Kind.Jump => true
      | _ => false

fun shouldBounceAt (Block.T {kind, ...}) =
   (* This is based on the allocate
    * registers choice, of which variables
    * go to the stack, and similarly,
    * cannot be frivolously changed *)
   case Kind.frameStyle kind of
        Kind.OffsetsAndSize => true
      | _ => false

structure Weight = struct

   structure DefLoc = struct
      datatype t
         = FunArg
         | Local

      fun op < (t1, t2) =
         case (t1, t2) of
               (FunArg, Local) => true
             | _ => false
      val equals = op =
   end

   type t = {count: int, localDef: DefLoc.t}
   fun inc ({count, localDef}) =
      {count=count + 1, localDef=localDef}
   val new = {count=0, localDef=DefLoc.Local}
   fun op < ({count=count1, localDef=localDef1},
             {count=count2, localDef=localDef2}) =
      (DefLoc.< (localDef1, localDef2)
         orelse DefLoc.equals (localDef1, localDef2)
            andalso (Int.< (count1, count2)))
   fun setLocalDef ({count, localDef=_}, newLocalDef) =
      {count=count, localDef=newLocalDef}
end

datatype varinfo
   = Ignore
   | Consider of Weight.t
   | Rewrite of Weight.t

fun loopForeach ({headers, child}, f) =
   case DirectedGraph.LoopForest.dest child of
        {loops, notInLoop} =>
        let
           val _ = Vector.foreach (headers, f)
           val _ = Vector.foreach (notInLoop, f)
        in
           Vector.foreach (loops, fn loop => loopForeach (loop, f))
        end

fun transformFunc func =
   let
      val {args, blocks, name, raises, returns, start} = Function.dest func
      val liveInfo = Live.live (func, {shouldConsider = fn _ => true})
      fun beginNoFormals label = #beginNoFormals ((#labelLive liveInfo) label)

      val {loops, ...} = DirectedGraph.LoopForest.dest
         (Function.loopForest (func, fn (b, _) =>
            shouldAvoid b))

      val {get=varTy, set=setVarTy, ...} = Property.getSetOnce
         (Var.plist, Property.initRaise ("SeparateVars.transformFunc.varTy", Var.layout))

      val _ = Function.foreachDef (func, setVarTy)

      val {get=varInfo, set=setVarInfo, ...} = Property.getSet
         (Var.plist, Property.initConst Ignore)

      val _ = Vector.foreach (blocks,
         fn b as Block.T {label, ...} =>
            if shouldBounceAt b
            then Vector.foreach (beginNoFormals label,
               fn v => setVarInfo (v, Consider Weight.new))
            else ())
      (* foreach arg, set Consider? need to tell it how to
       * avoid setting the original again *)
      val _ = Vector.foreach (args,
         fn (x, _) =>
            case varInfo x of
                 Consider w =>
                  setVarInfo (x, Consider (Weight.setLocalDef (w,
                     Weight.DefLoc.FunArg)))
               | _ => ())


      datatype InLoop
        = InLoop of {header: bool}
        | NotInLoop

      val {get=labelInfo, ...} = Property.get
         (Label.plist, Property.initFun
            (fn _ => {inLoop=ref NotInLoop, block=ref NONE}))

      val numRewritten = ref 0

      fun setRewrite (v, weight) =
         case varInfo v of
              Consider _ =>
                  if Control.optFuelAvailAndUse ()
                  then ( Int.inc numRewritten ; setVarInfo (v, Rewrite weight))
                  else ()
            | _ => ()

      val n = !Control.bounceRssaLimit
      val _ = Control.diagnostic (fn () =>
         let
            open Layout
         in
            seq [str "Bounce rssa limit: ", Option.layout Int.layout n]
         end)
      val _ = let
         (* now for each var in consideration, check if active in loop *)
         fun count reff _ = Int.inc reff
         fun checkActiveVars (block as Block.T {label, ...}) =
           let
              fun modVarInfo (v, f) =
                 let
                    val newInfo =
                       case varInfo v of
                            Ignore => Ignore
                          | Consider w => Consider (f w)
                          | Rewrite _ => Error.bug "Unexpected Rewrite"
                    val _ = setVarInfo (v, newInfo)
                 in
                    ()
                 end
              val _ = Block.foreachDef (block,
                  fn (v, _) =>
                     modVarInfo (v,
                        fn w => Weight.inc (Weight.setLocalDef (w,
                           Weight.DefLoc.Local))))

              val _ = Block.foreachUse (block,
                  fn v =>
                     case n of
                          NONE => setRewrite (v, Weight.new)
                        | SOME _ => modVarInfo (v,
                             fn w => Weight.inc w))
              val _ = (#inLoop o labelInfo) label :=
                InLoop {header=false}
           in
             ()
           end
         fun setHeader (Block.T {label, ...}) =
            let
               val inLoop = (#inLoop o labelInfo) label
            in
               case !inLoop  of
                    InLoop {...} => inLoop := InLoop {header=true}
                  | _ => ()
            end
         fun processLoop (loop as {headers,...}) =
            let
               val size = ref 0
               val _ = loopForeach (loop, count size)
               val _ =
                  (* this bound is a conservative bound
                   * backed up by data showing no improvements at
                   * all over this size, so we'll save the overhead *)
                  if !size < 40
                  then loopForeach (loop, checkActiveVars)
                  else ()
               val _ = Vector.foreach (headers, setHeader)
            in
               ()
            end
      in
         Vector.foreach (loops, processLoop)
      end
      (* Process variables in two passes so that
       * the choices are consistent amongst different loops;
       * combined weights are taken into account and every variable
       * is either rewritten or ignored *)
      fun mkLoopPicker n loop =
         let
            (* assume n is small, else we should use a proper heap *)
            val heap = Array.new (n, (NONE, Weight.new))
            fun insert (i, x, xw) =
               if i >= n orelse
                     #count xw >= 15
                     (* Variables with lots of uses are usually worse
                      * candidates than shorter lived variables used once or
                      * twice since they have much longer lifespans,
                      * 15 is a conservative bound backed by some data *)
                  then ()
               else
                  let
                     val (y, yw) = Array.sub (heap, i)
                     val (x, xw) =
                        (* maximize weight *)
                        if (Weight.< (yw, xw))
                        then (Array.update (heap, i, (x, xw)) ; (y, yw))
                        else (x, xw)
                  in
                     insert (i + 1, x, xw)
                  end
            fun insertVar x =
               case
                  varInfo x of
                    Consider w => insert (0, SOME x, w)
                    (* Even if overlapped, we need to consider
                     * the weights more consistently *)
                  | Rewrite w => insert (0, SOME x, w)
                  | _ => ()
            fun insertVars block =
               Block.foreachUse (block, insertVar)
            val _ = loopForeach (loop, insertVars)
            val _ = Array.foreach (heap,
               fn (x, xw) =>
                  case x of
                       SOME x => setRewrite (x, xw)
                     | NONE => ())
         in
            ()
         end
      val _ = case n of
           SOME n => Vector.foreach (loops, mkLoopPicker n)
         | NONE => ()

      val _ = Vector.foreach (blocks,
         fn (b as Block.T {label, ...}) =>
            (#block o labelInfo) label := SOME b)

      val _ = Control.diagnostics (fn show =>
         let
            open Layout
         in
            show (seq [str "Function ", Func.layout name]) ;
            show (seq [str "Number of loops: ", (str o Int.toString o Vector.length) loops  ]) ;
            show (seq [str "Number of variables rewritten:: ", (str o Int.toString o !) numRewritten  ])
         end)


      datatype direction
         = EnterLoop
         | LeaveLoop

      val newBlocks = ref []

      fun insertRewriteBlock (destLabel, direction) =
         let
            val {block, ...} = labelInfo destLabel
            val Block.T {label=destLabel, args=destArgs, ...} = (valOf o !) block

            val args = Vector.map (destArgs, fn (v, ty) => (Var.new v, ty))
            val live = beginNoFormals destLabel

            val rewrites = Vector.keepAll (live, fn v =>
               case varInfo v of
                    Rewrite _ => true
                  | _ => false)
            val _ = Control.diagnostics (fn show =>
               let
                  open Layout
                  val _ =
                     show (seq [str "Dest Label ", Label.layout destLabel, str " (",
                                str (case direction of EnterLoop => "entrance" | LeaveLoop => "exit"),
                                str ")"])
               in
                  Vector.foreach (rewrites, fn v => show (seq [str "Rewriting ", Var.layout v]))
               end)
            val statements = Vector.map (rewrites,
               fn v =>
                  let
                     val ty = varTy v
                     val (src, dst) =
                        case direction of
                             EnterLoop => (v, v)
                           | LeaveLoop => (v, v)
                     val src = Operand.Var {var=src, ty=ty}
                     val dst = (dst, ty)
                  in
                     Statement.Bind {dst=dst, src=src,
                     (* temporary hack *)
                     isMutable= true}
                  end)
            (* we use our condition here, the kind of a block on the edge
             * of a loop is never anything interesting, since calls are
             * unconditional, there is always an intervening block
             * that would not be in the loop *)
            val kind = Kind.Jump
            val label = Label.new destLabel
            val jumpArgs = Vector.map (args, fn (v, ty) => Operand.Var {var=v, ty=ty})
            val transfer = Transfer.Goto {dst=destLabel, args=jumpArgs}
            val block = Block.T {args=args, kind=kind, label=label, statements=statements, transfer=transfer}
            val _ = List.push (newBlocks, block)
         in
            label
         end

      fun rewriteBlock (b as Block.T {args, kind, label, statements, transfer}) =
         let
            val {inLoop, ...} = labelInfo label
            val inLoop = !inLoop
            fun test l =
               let
                  val {inLoop=inLoop', ...} = labelInfo l
                  val inLoop' = !inLoop'
               in
                  case (inLoop, inLoop') of
                       (NotInLoop, InLoop _) => SOME EnterLoop
                     | (InLoop _, NotInLoop) => SOME LeaveLoop
                     | _ => NONE
               end
            val needsRewrite = ref false
            fun rewrite destLabel =
               case test destLabel of
                    NONE => destLabel
                  | SOME dir =>
                       ( needsRewrite := true ;
                         insertRewriteBlock (destLabel, dir))
            val newTransfer = Transfer.replaceLabels(transfer, rewrite)
            val newBlock = Block.T {args=args, kind=kind, label=label, statements=statements, transfer=newTransfer}
         in
            (* save some garbage if we don't need to change *)
            if !needsRewrite
               then newBlock
               else b
         end

      val _ = Vector.foreach (blocks, fn b => List.push (newBlocks, rewriteBlock b))
      val newBlocks = Vector.fromListRev (!newBlocks)
   in
      Function.new
         {args=args, blocks=newBlocks,
          name=name, raises=raises,
          returns=returns, start=start}
   end


fun transform p =
   let
      val Program.T {functions, handlesSignals, main, objectTypes} = p
      val restore = Restore.restoreFunction {main=main}
      val newFunctions = List.map(functions, restore o transformFunc)
   in
      Program.T {functions=newFunctions, handlesSignals=handlesSignals,
                 main=main, objectTypes=objectTypes}
   end

end
