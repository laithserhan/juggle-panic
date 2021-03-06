pico-8 cartridge // http://www.pico-8.com
version 16
__lua__
--juggle panic
--by bridgs
 
--[[
scenes:
	title
	title->game
	game-start
	game
	game-end
	game->title

update priority:
	1:	ball_sparks
	2:	stopwatch
	3:	ball_schwing
	4:	mode_notification
	5:	ball_icon
	6:	score_track
	7:	ball_spawner
	8:	ball
	9:	juggler
	10:	game_over_text_geysers
	11:	mode_select
	12:	title_screen
	13:	camera_operator
	14:	controls
	15:	speedometer

render layers:
	1:	stopwatch
	2:	ball_sparks
	3:	controls
	4:	mode_notification
	5:	game_over_text_geysers
	6:	ball_schwing
	7:	ball
	8:	ball_spawner
	9:	juggler
	10:	score_track
	11:	ball_icon
	12:	mode_select
	13:	title_screen
	14:	camera_operator
	15:	speedometer

sound efffects:
	0:	rise (slow)
	1:	rise (fast)
	2:	rise (faster)
	3:	rise (fastest)
	4:	fall (slow)
	5:	fall (fast)
	6:	fall (faster)
	7:	fall (fastest)
	8:	drop
	9:	pick up
	10:	catch
	11:	catch (faster)
	12:	mid-air collision
	13:	mid-air collision (faster)
	14:	mid-air collision (fastest)
	15:	title->game
	16:	game->title
	17:	game-end 1
	18:	game-end 2
	19:	mode change
	20:	explosion
	21:	notification appear
	22:	notification disappear
	23:	pong bounce
	37:	footsteps 1
	38:	footsteps 2
	39:	blackout static
	40:	wall bounce

sound channels:
	0:	footsteps
	1:	notification appear, notification disappear, drop, wall bounce
	2:	pick up, catch, explosion, pong bounce
	3:	rise, fall, mid-air collision, blackout static

music:
	2:	game end "music"
	4:	title screen music
]]

function noop() end

local next_ball_id=1
local ball_spawn_rate=1
local controllers={1,0}
local catch_fudge=1
local left_wall_x=1
local midpoint_x=64
local right_wall_x=127
local ground_y=114
local sky_y=1
local ball_colors={8,9,10,11,12}
local dark_ball_colors={2,4,4,3,1}
local modes={
	"normal mode",
	"bomb mode",
	"blackout mode",
	"cooperative mode",
	"noodle arms mode",
	"sudden death",
	"speedball mode",
	"bodybuilder mode",
	"pong mode",
	"leapfrog mode",
	"avant-garde mode",
	"credits",
	"random"
}
local tips={
	{"first to drop","5 balls loses"},
	{"don't get","exploded"},
	nil,
	{"survive for","40 seconds"}
}
local credits_messages={
	"created","with","love","by","bridgs!",
	"follow","@bridgs_dev","on","twitter",
	"thanks","for","playing!",
	"wait","stop","please","don't-"
}

local buttons
local button_presses
local buffered_button_presses

local scene
local game_frame
local screen_shake_frames
local standstill_frames
local inactive_frames
local show_controls
local occasional_ball_spawn_frames
local next_occasional_ball_spawn
local ball_speed_rating
local rainbow_color_index
local max_marks
local mode
local tip
local entities
local new_entities
local jugglers
local balls
local title_screen
local camera_operator

local entity_classes={
	juggler={
		update_priority=9,
		render_layer=9,
		width=18,
		height=11,
		move_x=0,
		left_hand_ball=nil,
		right_hand_ball=nil,
		most_recent_catch_hand=nil,
		anim=nil,
		anim_frames=0,
		sprite_num=0,
		sprite_flipped=false,
		stationary_frames=0,
		wiggle_frames=0,
		throw_cooldown_frames=0,
		add_to_game=function(self)
			jugglers[self.player_num]=self
		end,
		on_scene_change=function(self)
			self.is_paused=(scene=="title->game")
			if scene=="game-end" then
				self.spawner=nil
				self.left_hand_ball=nil
				self.right_hand_ball=nil
			elseif scene=="title" then
				self:die()
			end
		end,
		init=function(self)
			self:calc_hand_hitboxes()
			self.update_priority+=rnd()/10
		end,
		update=function(self)
			local controller=controllers[self.player_num]
			-- move horizontally when left/right buttons are pressed
			local is_touching_ground=(self.y>=ground_y-self.height)
			self.move_x=ternary(buttons[controller][1],1,0)-
				ternary(buttons[controller][0],1,0)
			local move_speed
			if self.left_hand_ball and self.right_hand_ball then
				move_speed=1
			elseif self.left_hand_ball or self.right_hand_ball then
				move_speed=2
			else
				move_speed=4
			end
			if mode=="bodybuilder mode" then
				move_speed=2
			end
			if mode=="leapfrog mode" then
				if is_touching_ground then
					if self.move_x==0 then
						self.vx=0
					else
						self.vx=move_speed*self.move_x
						self.vy=-12.5
					end
				end
				self.vy+=2
			else
				self.vx=move_speed*self.move_x
				-- don't move if forced to be stationary (during throws/catches)
				if self.stationary_frames>0 then
					self.vx=0
				end
			end
			decrement_counter_prop(self,"stationary_frames")
			self:apply_velocity()
			if mode=="leapfrog mode" then
				self.y=min(ground_y-self.height,self.y)
			end
			-- keep the juggler in bounds
			if self.x<self.min_x then
				self.x=self.min_x
				self.vx=max(0,self.vx)
			elseif self.x>self.max_x-self.width then
				self.x=self.max_x-self.width
				self.vx=min(0,self.vx)
			end
			-- throw balls
			decrement_counter_prop(self,"throw_cooldown_frames")
			if self.throw_cooldown_frames<=0  and (buffered_button_presses[controller][4]>0 or buffered_button_presses[controller][5]>0) then
				buffered_button_presses[controller][4]=0
				buffered_button_presses[controller][5]=0
				local preferred_throw_hand=ternary(self.most_recent_catch_hand=="left","right","left")
				if self.move_x<0 then
					preferred_throw_hand="left"
				elseif self.move_x>0 then
					preferred_throw_hand="right"
				end
				if self.left_hand_ball or self.right_hand_ball then
					self.anim="throw"
					self.anim_frames=20
					self.wiggle_frames=0
					if mode!="leapfrog mode" then
						self.vx=0
					end
					self.stationary_frames=max(6,self.stationary_frames)
					self.throw_cooldown_frames=4
				end
				-- throw with the left hand unless the right hand is preferred and can throw instead
				local thrown_ball
				if self.left_hand_ball and (preferred_throw_hand=="left" or not self.right_hand_ball) then
					self.sprite_flipped=false
					self:calc_sprite_num()
					self:reposition_held_balls()
					thrown_ball=self.left_hand_ball
					self.left_hand_ball=nil
				elseif self.right_hand_ball then
					self.sprite_flipped=true
					self:calc_sprite_num()
					self:reposition_held_balls()
					thrown_ball=self.right_hand_ball
					self.right_hand_ball=nil
				end
				if thrown_ball then
					thrown_ball.is_held_by_juggler=false
					-- figure out throw distance
					local throw_dist=63
					if mode=="bodybuilder mode" then
						throw_dist*=10
					end
					local ball_center=thrown_ball.x+thrown_ball.width/2
					local landing_x=ball_center+self.throw_dir*throw_dist
					-- make it a little more obvious which side the ball is going to land on
					if landing_x==mid(midpoint_x-4,landing_x,midpoint_x) then
						throw_dist=self.throw_dir*(midpoint_x-4-ball_center)
					end
					if landing_x==mid(midpoint_x,landing_x,midpoint_x+4) then
						throw_dist=self.throw_dir*(midpoint_x+4-ball_center)
					end
					-- figure out throw duration
					local throw_dur=mid(6,flr(150/(1+ball_speed_rating/3)),100)
					-- figure out throw height
					local throw_height=mid(71,70+flr(1.2*ball_speed_rating),120)
					if mode=="avant-garde mode" then
						throw_height=100
					end
					-- throw the ball!
					thrown_ball:throw(self.throw_dir*throw_dist,throw_height,throw_dur)
					-- balls travel faster and faster
					if mode!="cooperative mode" then
						ball_speed_rating=min(ball_speed_rating+1,100)
					end
				end
			end
			-- catch balls
			self:calc_hand_hitboxes()
			local ball
			for ball in all(balls) do
				if mode!="pong mode" and not ball.is_held_by_juggler and ball.vy>=0 and (not ball.is_held_by_spawner or ball.spawner.is_above_ground) then
					local is_catching_with_left_hand=(self.left_hand_hitbox and rects_overlapping(self.left_hand_hitbox,ball.hurtbox))
					local is_catching_with_right_hand=(self.right_hand_hitbox and rects_overlapping(self.right_hand_hitbox,ball.hurtbox))
					if is_catching_with_left_hand or is_catching_with_right_hand then
						if ball.is_held_by_spawner then
							ball.spawner.held_ball=nil
							ball.spawner=nil
							ball.is_held_by_spawner=false
							self.stationary_frames=max(2,self.stationary_frames)
							sfx(9,2) -- pick up
							self.anim_frames=20
							self.anim="catch"
							self.wiggle_frames=0
							if mode!="leapfrog mode" then
								self.vx=0
							end
							self.throw_cooldown_frames=ternary(self.left_hand_ball or self.right_hand_ball,0,min(4,self.throw_cooldown_frames))
						elseif mode=="bomb mode" then
							mark_ball_dropped(ball)
							is_catching_with_left_hand=false
							is_catching_with_right_hand=false
						else
							self.stationary_frames=max(3,self.stationary_frames)
							sfx(ternary(ball_speed_rating>25,11,10),2) -- catch
							self.anim_frames=20
							self.anim="catch"
							self.wiggle_frames=0
							if mode!="leapfrog mode" then
								self.vx=0
							end
							self.throw_cooldown_frames=ternary(self.left_hand_ball or self.right_hand_ball,0,min(4,self.throw_cooldown_frames))
						end
					end
					-- catch with the left hand if the right can't catch it or if the right is farther from the ball
					if is_catching_with_left_hand and (not is_catching_with_right_hand or ball.x+ball.width/2<self.x+self.width/2) then
						self.left_hand_ball=ball
						self.left_hand_hitbox=nil
						ball:catch()
						self.sprite_flipped=true
						self.most_recent_catch_hand="left"
					-- otherwise catch with the right hand
					elseif is_catching_with_right_hand then
						self.right_hand_ball=ball
						self.right_hand_hitbox=nil
						ball:catch()
						self.sprite_flipped=false
						self.most_recent_catch_hand="right"
					end
				end
			end
			-- calc render data
			if self.anim and self.vx!=0 and mode!="leapfrog mode" then
				self.anim_frames=0
				self.anim=nil
				self.sprite_flipped=not self.sprite_flipped
			end
			if decrement_counter_prop(self,"anim_frames") then
				self.anim=nil
				self.sprite_flipped=not self.sprite_flipped
			end
			self:calc_sprite_num()
			if not self.anim then
				increment_counter_prop(self,"wiggle_frames")
				local wiggle_dur
				if self.move_x==0 then
					wiggle_dur=20
				elseif mode=="bodybuilder mode" then
					wiggle_dur=6
				elseif self.left_hand_ball and self.right_hand_ball then
					wiggle_dur=12
				elseif self.left_hand_ball or self.right_hand_ball then
					wiggle_dur=6
				else
					wiggle_dur=3
				end
				if self.wiggle_frames>wiggle_dur then
					self.sprite_flipped=not self.sprite_flipped
					self.wiggle_frames=0
					if self.move_x!=0 then
						sfx(ternary(self.player_num==1,38,37),0)
					end
				end
			end
			-- reposition any held balls
			self:reposition_held_balls()
		end,
		draw=function(self)
			-- self:draw_outline(14)
			if mode=="pong mode" then
				rectfill(self.x+0.5,self.y-3.5,self.x+self.width-0.5,self.y-1.5,7)
			else
				pal(7,ternary(mode=="leapfrog mode",3,0))
			end
			if mode=="bodybuilder mode" then
				pal(1,0)
			else
				palt(1,true)
			end
			if mode!="leapfrog mode" then
				palt(3,true)
				palt(14,true)
			end
			if mode=="blackout mode" and screen_shake_frames>0 then
				colorwash(7)
			end
			if mode=="noodle arms mode" then
				draw_sprite(52,76+13*self.sprite_num,36,13,self.x,self.y-2,self.sprite_flipped)
			else
				draw_sprite(0,8+14*self.sprite_num,18,14,self.x,self.y-3,self.sprite_flipped)
			end
			pal()
			if self.anim=="catch" and self.anim_frames>=10 then
				if self.sprite_flipped then
					draw_sprite(22,41,10,6,self.x-3,self.y,true)
				else
					draw_sprite(22,41,10,6,self.x+self.width-7,self.y)
				end
			end
		end,
		calc_sprite_num=function(self)
			if self.anim=="catch" then
				self.sprite_num=2
			elseif self.anim=="throw" then
				self.sprite_num=1
			else
				self.sprite_num=0
			end
		end,
		calc_hand_hitboxes=function(self)
			if self.left_hand_ball then
				self.left_hand_hitbox=nil
			else
				self.left_hand_hitbox={
					x=self.x,
					y=self.y+1,
					width=7,
					height=self.height+ternary(mode=="leapfrog mode",max(0,-self.vx),-1)
				}
				if mode!="bomb mode" then
					if self.vx<0 then
						self.left_hand_hitbox.x+=self.vx
						self.left_hand_hitbox.width-=self.vx
					else
						self.left_hand_hitbox.x-=catch_fudge
						self.left_hand_hitbox.width+=catch_fudge
					end
					if self.right_hand_ball then
						if self.vx>0 then
							self.left_hand_hitbox.width+=self.vx
						else
							self.left_hand_hitbox.width+=catch_fudge
						end
					end
				end
			end
			if self.right_hand_ball then
				self.right_hand_hitbox=nil
			else
				self.right_hand_hitbox={
					x=self.x+self.width-7,
					y=self.y+1,
					width=7,
					height=self.height+ternary(mode=="leapfrog mode",15,-1)
				}
				if mode!="bomb mode" then
					if self.vx>0 then
						self.right_hand_hitbox.width+=self.vx
					else
						self.right_hand_hitbox.width+=catch_fudge
					end
					if self.left_hand_ball then
						if self.vx<0 then
							self.right_hand_hitbox.x+=self.vx
							self.right_hand_hitbox.width-=self.vx
						else
							self.right_hand_hitbox.x-=catch_fudge
							self.right_hand_hitbox.width+=catch_fudge
						end
					end
				end
			end
		end,
		reposition_held_balls=function(self)
			local bonus_x=ternary(mode=="noodle arms mode",10,0)
			-- calculate hand positions
			local lx,ly,rx,ry
			if self.sprite_num==2 then
				lx,ly,rx,ry=7,2,7,8
			elseif self.sprite_num==1 then
				lx,ly,rx,ry=7,4,7,7
			else
				lx,ly,rx,ry=7,3,7,7
			end
			if self.sprite_flipped then
				lx,ly,rx,ry=rx,ry,lx,ly
			end
			-- move any held balls to those positions
			if self.left_hand_ball then
				self.left_hand_ball.x=self.x+self.width/2-lx-2-bonus_x
				self.left_hand_ball.y=self.y+ly-self.left_hand_ball.height
			end
			if self.right_hand_ball then
				self.right_hand_ball.x=self.x+self.width/2+rx+2-self.right_hand_ball.width+bonus_x
				self.right_hand_ball.y=self.y+ry-self.right_hand_ball.height
			end
		end
	},
	ball={
		update_priority=8,
		render_layer=7,
		width=5,
		height=5,
		gravity=0,
		freeze_frames=0,
		collision_immune_frames=0,
		bounce_dir=nil,
		is_held_by_juggler=false,
		is_held_by_spawner=false,
		color=7,
		sound_level=1,
		add_to_game=function(self)
			add(balls,self)
		end,
		remove_from_game=function(self)
			del(balls,self)
			-- if there are no more balls, spawn two more
			if scene=="game" then
				local num_active_balls=0
				foreach(balls,function(ball)
					if not ball.is_held_by_spawner then
						num_active_balls+=1
					end
				end)
				if num_active_balls<=0 and mode!="bomb mode" and mode!="speedball mode" then
					ball_speed_rating=max(1,flr(0.3*ball_speed_rating))
				end
				if #balls<=0 then
					jugglers[1].spawner:spawn_ball()
					jugglers[2].spawner:spawn_ball()
					standstill_frames=280/ball_spawn_rate
				end
			end
		end,
		on_scene_change=function(self)
			if scene=="game-end" then
				self:die()
			end
		end,
		init=function(self)
			self.id=next_ball_id
			next_ball_id=increment_counter(next_ball_id)
			if mode=="credits" then
				self.render_layer=9.5
				self.color=ternary(credits_messages[self.id]=="love",8,7)
			end
			self:calc_hurtbox()
			self.energy=self.vy*self.vy/2+self.gravity*(ground_y-self.y-self.height)
			self.prev_x,self.prev_y=self.x,self.y
		end,
		update=function(self)
			decrement_counter_prop(self,"collision_immune_frames")
			if self.is_held_by_juggler or self.is_held_by_spawner then
				self.prev_x,self.prev_y=self.x,self.y
				decrement_counter_prop(self,"freeze_frames")
			else
				if self.freeze_frames>0 then
					decrement_counter_prop(self,"freeze_frames")
				else
					self.bounce_dir=nil
					local prev_vy=self.vy
					self.vy+=self.gravity
					self.prev_x,self.prev_y=self.x,self.y
					-- apply velocity manually
					self.y+=self.vy
					if self.y>=ground_y-self.height then
						self.x+=self.vx/3
					else
						self.x+=self.vx
					end
					-- play a falling sound
					if prev_vy<=1 and self.vy>1 then
						sfx(self.sound_level+3,3) -- fall
					end
					-- if a ball goes across the midpoint, there's no standstill
					if (self.prev_x<midpoint_x)!=(self.x<midpoint_x) then
						standstill_frames=max(180/ball_spawn_rate,standstill_frames)
					end
					self:calc_hurtbox()
					-- bounce off walls
					if self.x<left_wall_x then
						self.x=left_wall_x
						self:calc_hurtbox()
						if self.vx<0 then
							self.vx*=-1
							self.bounce_dir="left"
							self.freeze_frames=1
						end
					elseif self.x>right_wall_x-self.width then
						self.x=right_wall_x-self.width
						self:calc_hurtbox()
						if self.vx>0 then
							self.vx*=-1
							self.bounce_dir="right"
							self.freeze_frames=1
						end
					end
					if mode=="pong mode" then
					-- bounce off players
						if self.vy>0 and self.y==mid(ground_y-8,self.y,ground_y-20) then
							local center_x=self.x+self.width/2
							local player_num=ternary(center_x<midpoint_x,1,2)
							local juggler=jugglers[player_num]
							local dx=center_x-juggler.x-juggler.width/2
							if abs(dx)<juggler.width/2 then
								self.y=ground_y-20
								self.bounce_dir="down"
								self.freeze_frames=1
								self.vx=self.vx+juggler.vx/8+dx*self.vy/10
								self.vy=-self.vy-0.7
								-- self.vx+=dx/10
							end
						end
						-- bounce off the ceiling
						if self.y<1 then
							self.y=1
							if self.vy<0 then
								self.vy*=-1
								self.bounce_dir="up"
								self.freeze_frames=1
							end
						end
					end
					if self.bounce_dir then
						if mode=="pong mode" then
							sfx(23,2) -- pong bounce
						else
							sfx(40,1) -- wall bounce
						end
					end
					-- bounce off the ground
					-- if self.y>ground_y-self.height then
					-- 	self.y=ground_y-self.height
					-- 	self:calc_hurtbox()
					-- 	if self.vy>0 then
					-- 		-- we do this so that balls don't lose energy over time
					-- 		self.vy=-sqrt(2*self.energy)
					-- 		self.bounce_dir="down"
					-- 		self.freeze_frames=2
					-- 	end
					-- end
				end
			end
		end,
		post_update=function(self)
			-- balls that hit the ground die
			if self.is_alive and not self.is_held_by_juggler and not self.is_held_by_spawner and self.y>=ground_y-self.height then
				mark_ball_dropped(self)
			end
			-- recalculate hurtboxes again
			self:calc_hurtbox()
		end,
		draw=function(self)
			-- each ball has a color
			colorwash(self.color)
			-- draw the ball squished against the wall/ground
			if mode=="credits" then
				local message=credits_messages[self.id]
				print(message,self.x-2*#message+3.5,self.y+0.5,7)
			elseif self.bounce_dir then
				if self.bounce_dir=="left" or self.bounce_dir=="right" then
					if abs(self.vx)<1 then
						spr(0,self.x-0.5,self.y-0.5)
					else
						draw_sprite(ternary(abs(self.vx)>5,40,36),88,4,9,self.x+ternary(self.bounce_dir=="right",1,0),self.y-2,self.bounce_dir=="left")
					end
				elseif self.bounce_dir=="down" or self.bounce_dir=="up" then
					if abs(self.vy)<1 then
						spr(0,self.x-0.5,self.y-0.5)
					else
						draw_sprite(24,ternary(abs(self.vy)>18,80,76),9,4,self.x-2,self.y+1,false,self.bounce_dir=="up")
					end
				end
			else
				local speed=sqrt(self.vx*self.vx+self.vy*self.vy)
				-- if it's going slow, just draw an undeformed ball
				if speed<5 then
					spr(0,self.x-0.5,self.y-0.5)
				-- otherwise draw a deformed version
				else
					local angle=atan2(self.vx,self.vy)
					local flip_horizontal=(self.vx<0)
					local flip_vertical=(self.vy>0)
					-- figure out which sprite we're going to use
					local sprite_num=flr(24*angle+0.5)
					if flip_vertical then
						sprite_num=24-sprite_num
					end
					if flip_horizontal then
						sprite_num=max(0,12-sprite_num)
					end
					-- find the right sprite location based on angle
					local sy,sw,sh
					if sprite_num==0 then
						sy,sw,sh=123,16,5
					elseif sprite_num==1 then
						sy,sw,sh=117,15,6
					elseif sprite_num==2 then
						sy,sw,sh=108,13,9
					elseif sprite_num==3 then
						sy,sw,sh=97,11,11
					elseif sprite_num==4 then
						sy,sw,sh=84,9,13
					elseif sprite_num==5 then
						sy,sw,sh=69,6,15
					elseif sprite_num==6 then
						sy,sw,sh=53,5,16
					end
					-- find the right sprite location based on speed
					local sx=mid(0,flr((speed-5)/9),3)*sw
					local x,y=self.x,self.y
					-- handle the other 270 degrees
					if not flip_horizontal then
						x+=self.width-sw
					end
					if flip_vertical then
						y+=self.height-sh
					end
					-- draw the sprite
					draw_sprite(sx,sy,sw,sh,x,y,flip_horizontal,flip_vertical)
				end
			end
		end,
		on_death=function(self)
			if scene=="game" and mode=="pong mode" then
				spawn_entity("ball",60.5,31.5,{
					vx=rnd_int(0,1)-0.5,
					vy=1.2,
					color=7
				})
			end
		end,
		throw=function(self,distance,height,duration)
			-- let's do some fun math to calculate out the trajectory
			-- duration must be <=180, otherwise overflow will ruin the math
			-- it looks best if duration is an even integer (you get to see the apex)
			local n=(duration+1)*duration/2
			local m=(duration/2+1)*duration/4
			self.vy=n/(m-n/2)
			self.vy*=height/duration
			self.gravity=-self.vy*duration/n
			self.vx=distance/duration
			-- calculate kinetic and potential energy
			self.energy=self.vy*self.vy/2+self.gravity*(ground_y-self.y-self.height)
			-- play a rising sound
			if ball_speed_rating>=25 then
				self.sound_level=4
			elseif ball_speed_rating>=15 then
				self.sound_level=3
			elseif ball_speed_rating>=8 then
				self.sound_level=2
			else
				self.sound_level=1
			end
			sfx(self.sound_level-1,3) -- rise
		end,
		catch=function(self)
			self.is_held_by_juggler=true
			self.freeze_frames=0
			self.vx=0
			self.vy=0
			self.bounce_dir=nil
		end,
		calc_hurtbox=function(self)
			self.hurtbox={
				x=self.x,
				y=self.y,
				width=self.width,
				height=self.height
			}
			if self.vy>0 then
				self.hurtbox.y-=self.vy
				self.hurtbox.height+=self.vy
			elseif self.vy<0 then
				self.hurtbox.height-=self.vy
			end
			if self.vx<0 then
				self.hurtbox.width+=mid(0,-self.vx,2)
			end
			if self.vx>0 then
				self.hurtbox.x-=mid(0,self.vx,2)
				self.hurtbox.width+=mid(0,self.vx,2)
			end
		end
	},
	ball_sparks={
		update_priority=1,
		render_layer=2,
		y=ground_y-5,
		width=5,
		height=5,
		frames_to_death=40,
		init=function(self)
			self.particles={}
			local i
			for i=1,ternary(mode=="avant-garde mode",200,50) do
				local x,y=self.x+self.width/2,self.y+self.height
				local speed=0.2+3*rnd()*rnd()
				add(self.particles,{
					x=x,
					y=y,
					prev_x=x,
					prev_y=y,
					vx=ternary(mode=="avant-garde mode",3,1)*(rnd(1.2)+rnd(1.2)-1.2)*speed,
					vy=-7*speed,
					visibile_frames=rnd_int(5,40)
				})
			end
		end,
		update=function(self)
			foreach(self.particles,function(particle)
				particle.vy*=0.95
				particle.vx*=0.95
				particle.prev_x=particle.x
				particle.prev_y=particle.y
				particle.x+=particle.vx
				particle.y+=particle.vy
			end)
		end,
		draw=function(self)
			foreach(self.particles,function(particle)
				if self.frames_alive<particle.visibile_frames then
					line(particle.prev_x+0.5,particle.prev_y+0.5,particle.x+0.5,particle.y+0.5,self.color)
				end
			end)
		end
	},
	ball_schwing={
		update_priority=3,
		render_layer=6,
		width=12,
		height=22,
		draw=function(self)
			if self.is_big then
				pal(15,7)
			else
				palt(15,true)
			end
			draw_sprite(20,47,12,22,self.x,self.y,self.flipped)
			-- self:draw_outline(8)
		end
	},
	ball_icon={
		update_priority=5,
		render_layer=11,
		width=5,
		height=5,
		color=7,
		frames_to_death=90,
		draw=function(self)
			pal(7,self.color)
			spr(3,self.x-0.5,self.y+0.5)
		end
	},
	ball_spawner={
		update_priority=7,
		render_layer=8,
		width=5,
		height=4,
		held_ball=nil,
		is_above_ground=false,
		on_scene_change=function(self)
			if scene=="game-end" then
				self:die()
			end
		end,
		update=function(self)
			local spawn_speed=0.1
			if mode=="speedball mode" then
				spawn_speed=1
			end
			if self.held_ball then
				self.y=max(ground_y-self.height,self.y-spawn_speed)
				self.held_ball.y=self.y-4
			else
				self.y=min(ground_y+3,self.y+spawn_speed)
			end
			self.is_above_ground=(self.y<=ground_y-1.5)
			if self.frames_alive==80 and mode!="cooperative mode" then
				self:spawn_ball()
			end
			-- in cooperative mode, balls are flung into the air
			if mode=="cooperative mode" then
				if self.frames_alive%260==120 then
					self:spawn_ball()
				end
				if self.held_ball and self.is_above_ground then
					self.held_ball.spawner=nil
					self.held_ball.is_held_by_spawner=false
					-- figure out throw duration
					local throw_dur=mid(6,flr(150/(1+ball_speed_rating/3)),100)
					-- figure out throw height
					local throw_height=mid(71,70+flr(1.2*ball_speed_rating),120)
					self.held_ball:throw(0,throw_height,throw_dur)
					self.held_ball=nil
				end
			end
		end,
		draw=function(self)
			pal(7,0)
			draw_sprite(36,84,5,4,self.x,self.y)
		end,
		on_game_end=function(self)
			self.held_ball=nil
		end,
		spawn_ball=function(self)
			if scene=="game" and mode!="pong mode" then
				occasional_ball_spawn_frames=440/ball_spawn_rate
				if not self.held_ball then
					local color=ball_colors[rnd_int(1,#ball_colors)]
					if mode=="bomb mode" then
						color=5
					elseif mode=="pong mode" then
						color=7
					end
					self.held_ball=spawn_entity("ball",self.x,self.y-4,{
						is_held_by_spawner=true,
						spawner=self,
						color=color
					})
				end
				return true
			else
				return false
			end
		end
	},
	score_track={
		update_priority=6,
		render_layer=10,
		y=ground_y+6,
		width=39,
		height=7,
		on_scene_change=function(self)
			if scene=="title" then
				self:die()
			end
		end,
		init=function(self)
			self.marks={}
		end,
		draw=function(self)
			if mode=="pong mode" then
				print(#self.marks,self.x+18.5,self.y+1.5,7)
			else
				local i
				local offset=(5-max_marks)*4
				for i=1,max_marks do
					local sprite=1
					if self.marks[i] then
						sprite=2
						pal(7,self.marks[i])
					end
					spr(sprite,self.x+8*i-7.5+offset,self.y+0.5)
				end
			end
		end,
		add_mark=function(self,color)
			add(self.marks,color)
		end
	},
	camera_operator={
		update_priority=13,
		render_layer=14,
		y=-127,
		vy=0,
		update=function(self)
			-- fall up/down during scene transitions
			if scene=="title->game" or scene=="game-start" then
				self.vy+=0.5
			elseif scene=="game->title" then
				self.vy-=0.5
			end
			self:apply_velocity()
			-- bounce off bottom of screen
			if (scene=="title->game" or scene=="game-start") and self.y>0 then
				self.y=0
				self.vy=-0.25*self.vy
				if self.vy>-0.5 then
					self.vy=0
					change_scene("game")
				elseif scene!="game-start" then
					change_scene("game-start")
				end
			end
			-- bounce off top of screen
			if scene=="game->title" and self.y<-127 then
				self.y=-127
				self.vy=-0.25*self.vy
				if self.vy<0.5 then
					self.vy=0
					change_scene("title")
				end
			end
		end
	},
	title_screen={
		update_priority=12,
		render_layer=13,
		x=64,
		y=-64,
		frames_to_ball_spawn=1,
		on_scene_change=function(self)
			self.is_paused=(scene=="game-start" or scene=="game" or scene=="game-end")
		end,
		init=function(self)
			self.mode_select=spawn_entity("mode_select")
			self.balls={}
		end,
		update=function(self)
			local any_button_press=false
			local p
			for p=1,2 do
				local b
				for b=4,5 do
					if button_presses[controllers[p]][b] then
						any_button_press=true
					end
				end
			end
			if scene=="title" and any_button_press then
				music()
				sfx(15,1) -- title->game
				change_scene("title->game")
			end
			-- spawn a ball every now and then
			if decrement_counter_prop(self,"frames_to_ball_spawn") then
				self.frames_to_ball_spawn=rnd_int(12,24)
				local left_side=rnd()<0.5
				add(self.balls,{
					x=ternary(left_side,-5,127),
					y=-20-70*rnd(),--rnd_int(-100,-50),
					vx=ternary(left_side,2,-2),
					vy=-2.1-0.4*rnd(),
					color=ball_colors[rnd_int(1,#ball_colors)]
				})
			end
			-- update balls
			foreach(self.balls,function(ball)
				ball.vy+=0.06
				ball.x+=ball.vx
				ball.y+=ball.vy
				if ball.x<-15 or ball.x>137 then
					del(self.balls,ball)
				end
			end)
		end,
		draw=function(self)
			-- draw start prompt
			if self.frames_alive%28<21 and scene=="title" then
				print("press any button to start",self.x-49.5,self.y+50.5,5)
			end
			-- draw title
			self:draw_title(true)
			self:draw_title()
			-- draw balls
			pal()
			foreach(self.balls,function(ball)
				colorwash(ball.color)
				spr(0,ball.x+0.5,ball.y+0.5)
			end)
		end,
		draw_title=function(self,shadow)
			-- blue
			pal(12,ternary(shadow,1,12))
			pal(13,ternary(shadow,1,12))
			pal(1,ternary(shadow,1,12))
			-- green
			pal(11,ternary(shadow,3,11))
			pal(6,ternary(shadow,3,11))
			pal(3,ternary(shadow,3,11))
			-- yellow
			pal(10,ternary(shadow,4,10))
			pal(7,ternary(shadow,4,10))
			pal(5,ternary(shadow,4,10))
			-- orange
			pal(9,ternary(shadow,4,9))
			pal(15,ternary(shadow,4,9))
			pal(4,ternary(shadow,4,9))
			-- red
			pal(8,ternary(shadow,2,8))
			pal(14,ternary(shadow,2,8))
			pal(2,ternary(shadow,2,8))
			if self.frames_alive%28<15 then
				palt(13,true)
				palt(6,true)
				palt(7,true)
				palt(4,true)
				palt(14,true)
			else
				palt(1,true)
				palt(3,true)
				palt(5,true)
				palt(15,true)
				palt(2,true)
			end

			-- if self.frames_alive%20<10 then
			-- 	pal()
			-- else
			-- end
			draw_sprite(32,0,96,76,self.x-49+ternary(shadow,2,0),self.y-51+ternary(shadow,2,0))
		end
	},
	mode_select={
		update_priority=11,
		render_layer=12,
		x=16,
		y=-29,
		width=95,
		height=8,
		mode_index=1,
		mode_x=16,
		last_mode_index=nil,
		last_mode_x=64,
		last_mode_dir=1,
		line_length=0,
		on_scene_change=function(self)
			self.is_paused=(scene=="game-start" or scene=="game" or scene=="game-end")
		end,
		update=function(self)
			if scene=="title" then
				-- change modes
				if btnp(0,controllers[1]) or btnp(0,controllers[2]) then
					self:prev_mode()
				end 
				if btnp(1,controllers[1]) or btnp(1,controllers[2]) then
					self:next_mode()
				end
			end
			-- move modes into and out of view
			self.mode_x+=0.3*(self.x-self.mode_x)
			self.last_mode_x+=0.3*(self.x+87*self.last_mode_dir-self.last_mode_x)
			-- give the player an indiciation of how far they've scrolled
			local ideal_line_length=ternary(self.mode_index==1,0,76*((self.mode_index-1)/(#modes-1)))
			self.line_length+=0.3*(ideal_line_length-self.line_length)
		end,
		draw=function(self)
			-- draw current mode
			self:draw_mode(self.mode_index,self.mode_x)
			-- draw last mode
			if self.last_mode_index then
				self:draw_mode(self.last_mode_index,self.last_mode_x)
			end
			-- draw blinders
			rectfill(self.x-45.5,self.y+0.5,self.x+4.5,self.y+7.5,0)
			rectfill(self.x+90.5,self.y+0.5,self.x+141.5,self.y+7.5,0)
			-- draw progress line
			if self.line_length>0.1 then
				line(self.x+9.5,self.y+8.5,self.x+9.5+self.line_length,self.y+8.5,1)
			end
			-- draw left/right arrows
			local left_arrow_sprite=19
			local right_arrow_sprite=19
			if scene=="title" then
				if btnp(0,controllers[1]) or btnp(0,controllers[2]) then
					left_arrow_sprite=35
				elseif btn(0,controllers[1]) or btn(0,controllers[2]) then
					left_arrow_sprite=51
				end
				if btnp(1,controllers[1]) or btnp(1,controllers[2]) then
					right_arrow_sprite=35
				elseif btn(1,controllers[1]) or btn(1,controllers[2]) then
					right_arrow_sprite=51
				end
			else
				colorwash(1)
				palt(5,true)
			end
			spr(left_arrow_sprite,self.x-2.5,self.y+0.5,1,1)
			spr(right_arrow_sprite,self.x+90.5,self.y+0.5,1,1,true)
		end,
		next_mode=function(self)
			sfx(19,2) -- mode change
			self.last_mode_index=self.mode_index
			self.last_mode_x=self.x
			self.last_mode_dir=-1
			self.mode_index=1+self.mode_index%#modes
			self.mode_x=self.x+87
		end,
		prev_mode=function(self)
			sfx(19,2) -- mode change
			self.last_mode_index=self.mode_index
			self.last_mode_x=self.x
			self.last_mode_dir=1
			self.mode_index-=1
			if self.mode_index<=0 then
				self.mode_index=#modes
			end
			self.mode_x=self.x-87
		end,
		draw_mode=function(self,mode_index,x)
			local mode=modes[mode_index]
			-- figure out the right color for the mode (white or rainbow)
			local light_color,dark_color
			if mode_index==1 then
				light_color,dark_color=7,5
			else
				light_color,dark_color=ball_colors[rainbow_color_index],dark_ball_colors[rainbow_color_index]
			end
			print(mode,x+48.5-2*#mode,self.y+2.5,dark_color)
			print(mode,x+48.5-2*#mode,self.y+1.5,light_color)
		end
	},
	controls={
		update_priority=14,
		render_layer=3,
		frames_to_death=260,
		draw=function(self)
			local n=mid(0,flr(self.frames_alive/2)-80,100)
			if mode=="pong mode" then
				pal(13,0)
				palt(1,true)
				palt(3,true)
			end
			draw_sprite(88,91,9,10,14-n,48) -- s key
			draw_sprite(99,91,9,10,25-n,48) -- f key
			draw_sprite(91,118,9,10,93+n,48,true) -- left arrow key
			draw_sprite(91,118,9,10,104+n,48) -- right arrow key
			if mode!="pong mode" then
				draw_sprite(64,118,27,10,11-n,68) -- l-shift key
				draw_sprite(88,101,9,10,99+n,68) -- n key
			end
			pal()
			if mode=="blackout mode" or mode=="pong mode" then
				pal(0,7)
			end
			print("move",17.5-n,59.5,0)
			print("move",96.5+n,59.5,0)
			if mode !="pong mode" then
				print("toss",17.5-n,79.5,0)
				print("toss",96.5+n,79.5,0)
			end
		end
	},
	game_over_text_geysers={
		update_priority=10,
		render_layer=5,
		on_scene_change=function(self)
			if scene=="title" then
				self:die()
			end
		end,
		init=function(self)
			self.messages={}
		end,
		update=function(self)
			foreach(self.messages,function(msg)
				msg.vy+=0.2
				msg.x+=msg.vx
				msg.y+=msg.vy
			end)
		end,
		post_update=function(self)
			local f=self.frames_alive
			if f<40 or f==mid(60,f,70) or f==mid(80,f,85) or f==95 then
				local p
				for p=1,2 do
					local juggler=jugglers[p]
					local text
					if #juggler.score_track.marks>=max_marks then
						text=ternary(mode=="pong mode","0","lose")
					else
						text=ternary(mode=="pong mode","1","win")
					end
					add(self.messages,{
						text=text,
						x=juggler.x+juggler.width/2,
						y=ground_y,
						vx=rnd(0.9)-0.45,
						vy=-rnd(2.5)-4.5,
						color=ternary(mode=="pong mode",7,ball_colors[rnd_int(1,#ball_colors)])
					})
				end
			end
			if f==140 then
				sfx(16,1) -- game->title
				change_scene("game->title")
			end
		end,
		draw=function(self)
			foreach(self.messages,function(msg)
				print(msg.text,msg.x-2*#msg.text,msg.y,msg.color)
			end)
		end
	},
	stopwatch={
		update_priority=2,
		render_layer=1,
		x=56,
		y=14,
		width=14,
		height=17,
		on_scene_change=function(self)
			if scene=="game-end" then
				self:die()
			end
		end,
		update=function(self)
			if self.frames_alive==1496 then
				change_scene("game-end")
			end
		end,
		draw=function(self)
			if self.frames_alive>296 then
				local seconds=flr((self.frames_alive-296)/30)
				local i
				for i=1,8 do
					local show_red=seconds>5*i
					if self.frames_alive>=1496 then
						show_red=self.frames_alive%20<10
					end
					pal(i+7,ternary(show_red,8,7))
				end
				pal(1,8)
				pal(5,13)
				draw_sprite(104,104,14,17,self.x,self.y)
			end
		end
	},
	speedometer={
		update_priority=15,
		render_layer=15,
		x=49,
		y=ground_y+7,
		width=31,
		height=5,
		text="",
		color=1,
		on_scene_change=function(self)
			if scene=="title" then
				self:die()
			end
		end,
		update=function(self)
			local text,color
			if ball_speed_rating<5 then
				text,color="slow",1
			elseif ball_speed_rating<9 then
				text,color="fast",13
			elseif ball_speed_rating<13 then
				text,color="faster",12
			elseif ball_speed_rating<17 then
				text,color="v.fast",11
			elseif ball_speed_rating<21 then
				text,color="wowfast",10
			elseif ball_speed_rating<25 then
				text,color="aaahh!!",9
			elseif ball_speed_rating<30 then
				text,color="nonono!",8
			elseif ball_speed_rating<37 then
				text,color="max!!!",2
			elseif ball_speed_rating<50 then
				text,color="maxer!!",14
			elseif ball_speed_rating<70 then
				text,color="maxest!",15
			elseif ball_speed_rating<100 then
				text,color="rly now",7
			else
				text,color="error",8
			end
			self.text,self.color=text,color
		end,
		draw=function(self)
			print(self.text,self.x+16-2*#self.text,self.y,self.color)
		end
	},
	mode_notification={
		update_priority=4,
		render_layer=4,
		x=27,
		y=19,
		width=72,
		height=28,
		update=function(self)
			if self.frames_alive==80 then
				sfx(21,1) -- notification appear
			end
			if self.frames_to_death==12 then
				sfx(22,1) -- notification disappear
			end
		end,
		draw=function(self)
			local f=self.frames_alive-80
			local f2=self.frames_to_death
			pal(1,0)
			if mode=="pong mode" then
				pal(10,7)
			end
			if f==mid(0,f,2) or f2==mid(1,f2,3)then
				-- draw a pill version
				draw_sprite(108,91,8,8,self.x+27,self.y+10)
				draw_sprite(108,91,8,8,self.x+27+8,self.y+10,true)
			elseif f==mid(3,f,5) or f2==mid(4,f2,6)then
				-- draw a squished vertical version
				draw_sprite(118,104,10,17,self.x+30,self.y-9)
				sspr(118,121,10,1,self.x+30.5,self.y+8.5,10,10)
				draw_sprite(118,104,10,17,self.x+30,self.y+18,false,true)
			elseif f==mid(6,f,8) or f2==mid(7,f2,9)then
				-- draw a squished horizontal version
				draw_sprite(88,76,27,15,self.x-5,self.y+6)
				sspr(115,76,1,15,self.x+21.5,self.y+6.5,28,15)
				draw_sprite(88,76,27,15,self.x+49,self.y+6,true)
			elseif f>=9 then
				-- draw the actual sign
				local i
				for i=0,10 do
					draw_sprite(116,76,9,28,self.x+60-6*i,self.y)
				end
				draw_sprite(125,76,3,28,self.x+69,self.y)
				if mode and (f<100 or not tip) then
					print("activated",self.x+self.width/2-18.5,self.y+15.5,0)
					if f%30<22 then
						print("!",self.x+self.width/2+17.5,self.y+15.5,0)
					end
					print(mode,self.x+self.width/2-2*#mode+0.5,self.y+8.5,0)
				elseif not mode or f>105 then
					print(tip[1],self.x+self.width/2-2*#tip[1]+0.5,self.y+8.5,0)
					print(tip[2],self.x+self.width/2-2*#tip[2]+0.5,self.y+15.5,0)
				end
			end
		end,
		on_death=function(self)
			if mode=="pong mode" then
				spawn_entity("ball",60.5,31.5,{
					vx=rnd_int(0,1)-0.5,
					vy=1.2,
					color=7
				})
			end
		end
	}
}

function _init()
	-- initialize input vars
	buttons={}
	button_presses={}
	buffered_button_presses={}
	-- initialize game vars
	game_frame=0
	screen_shake_frames=0
	standstill_frames=0
	inactive_frames=0
	show_controls=true
	occasional_ball_spawn_frames=0
	next_occasional_ball_spawn=1
	ball_speed_rating=1
	rainbow_color_index=1
	mode=nil
	-- initialize entity vars
	entities={}
	new_entities={}
	jugglers={}
	balls={}
	-- start on the title screen
	change_scene("title")
	-- create our starting entities
	camera_operator=spawn_entity("camera_operator")
	title_screen=spawn_entity("title_screen")
	-- add new entities to the game
	add_new_entities()
end

function _update()
	-- keep track of inputs (because btnp repeats presses)
	local p
	for p=0,8 do
		if not buttons[p] then
			buttons[p]={}
			button_presses[p]={}
			buffered_button_presses[p]={}
		end
		local b
		for b=0,5 do
			button_presses[p][b]=btn(b,p) and not buttons[p][b]
			buttons[p][b]=btn(b,p)
			if button_presses[p][b] then
				buffered_button_presses[p][b]=4
				inactive_frames=0
			else
				buffered_button_presses[p][b]=decrement_counter(buffered_button_presses[p][b] or 0)
			end
		end
	end
	-- figure out the rainbow color
	rainbow_color_index=1+flr(game_frame/2)%#ball_colors
	game_frame=increment_counter(game_frame)
	screen_shake_frames=decrement_counter(screen_shake_frames)
	-- if players are inactive for too long, show the controls when the next game is started
	inactive_frames=increment_counter(inactive_frames)
	if inactive_frames>300 then
		show_controls=true
	end
	if scene=="game" and mode!="cooperative mode" and mode!="sudden death" then
		-- spawn a ball if there is ever a standstill
		standstill_frames=decrement_counter(standstill_frames)
		if standstill_frames<=0 then
			-- count the number of balls on each side
			local balls_per_player={0,0}
			foreach(balls,function(ball)
				if ball.x<midpoint_x then
					balls_per_player[1]+=1
				else
					balls_per_player[2]+=1
				end
			end)
			-- spawn a ball on each side if they have the same number of balls
			if balls_per_player[1]<=balls_per_player[2] then
				jugglers[1].spawner:spawn_ball()
			end
			if balls_per_player[1]>=balls_per_player[2] then
				jugglers[2].spawner:spawn_ball()
			end
			standstill_frames=280/ball_spawn_rate
		end
		-- spawn a ball every now and then to make things interesting
		occasional_ball_spawn_frames=decrement_counter(occasional_ball_spawn_frames)
		if occasional_ball_spawn_frames<=0 then
			if jugglers[next_occasional_ball_spawn].spawner:spawn_ball() then
				next_occasional_ball_spawn=3-next_occasional_ball_spawn
			else
				jugglers[3-next_occasional_ball_spawn].spawner:spawn_ball()
			end
		end
	end
	-- sort entities for updating
	sort(entities,function(entity1,entity2)
		return entity1.update_priority>entity2.update_priority
	end)
	-- update each entity
	local entity
	for entity in all(entities) do
		if not entity.is_paused then
			increment_counter_prop(entity,"frames_alive")
			entity:update()
			if decrement_counter_prop(entity,"frames_to_death") then
				entity:die()
			end
		end
	end
	for entity in all(entities) do
		if not entity.is_paused then
			entity:post_update()
		end
	end
	-- check for mid-air collisions
	local i
	for i=1,#balls do
		local ball1=balls[i]
		if ball1.is_alive and not ball1.is_held_by_juggler and not ball1.is_held_by_spawner and not ball1.is_paused and ball1.freeze_frames<=0 and ball1.collision_immune_frames<=0 then
			local j
			for j=i+1,#balls do
				local ball2=balls[j]
				if (ball1.vx<0)!=(ball2.vx<0) and ball2.is_alive and not ball2.is_held_by_juggler and not ball2.is_held_by_spawner and not ball2.is_paused and ball2.freeze_frames<=0 and ball2.collision_immune_frames<=0 then
					-- test for a collision
					local collision_exists=false
					local p
					for p=0,100,10 do
						if not collision_exists then
							local percent=p/100
							local x1,y1=ball1.x*percent+ball1.prev_x*(1-percent),ball1.y*percent+ball1.prev_y*(1-percent)
							local x2,y2=ball2.x*percent+ball2.prev_x*(1-percent),ball2.y*percent+ball2.prev_y*(1-percent)
							local dx,dy=x2-x1,y2-y1
							if abs(dx)<10 and abs(dy)<10 and dx*dx+dy*dy<2.9*2.9+2.9*2.9 then
								-- they collided!
								collision_exists=true
								local freeze_frames=mid(0,flr(ball_speed_rating/3)-1,30)
								ball1.freeze_frames=max(freeze_frames,ball1.freeze_frames)
								ball2.freeze_frames=max(freeze_frames,ball2.freeze_frames)
								ball1.collision_immune_frames=ball1.freeze_frames+ternary(mode=="bodybuilder mode",30,20)
								ball2.collision_immune_frames=ball2.freeze_frames+ternary(mode=="bodybuilder mode",30,20)
								-- bounce em!
								y1=max(5,y1)
								y2=max(5,y2)
								local dist=sqrt(dx*dx+dy*dy)
								local dist_to_add=(10-dist)
								ball1.x,ball1.y=x1,y1
								ball2.x,ball2.y=x2,y2
								ball1.vx,ball2.vx=1.7*ball2.vx,1.7*ball1.vx
								-- make a lil collision effect
								local sound
								if ball_speed_rating>20 then
									sound=14
								elseif ball_speed_rating>6 then
									sound=13
								else
									sound=12
								end
								sfx(sound,3) -- mid-air collision
								spawn_entity("ball_schwing",(x1+x2)/2-4,(y1+y2)/2-10,{
									frames_to_death=max(3,freeze_frames),
									flipped=((ball1.x<ball2.x and ball1.y>ball2.y) or (ball2.x<ball1.x and ball2.y>ball1.y)),
									is_big=(ball_speed_rating>=17)
								})
							end
						end
					end
				end
			end
		end
	end
	-- add new entities to the game
	add_new_entities()
	-- filter out dead entities
	for entity in all(entities) do
		if not entity.is_alive then
			del(entities,entity)
			entity:remove_from_game()
		end
	end
	-- sort entities for rendering
	sort(entities,function(entity1,entity2)
		return entity1.render_layer>entity2.render_layer
	end)
end

function _draw()
	-- shake the screen
	local screen_shake_y=-ceil(screen_shake_frames/2)*sin(screen_shake_frames/2.1)
	camera(0,screen_shake_y+camera_operator.y)
	local l,r=left_wall_x+0.5,right_wall_x-0.5
	if mode!="avant-garde mode" or game_frame<100 then
		-- clear the screen
		cls()
		-- draw the sky
		rectfill(l,sky_y+0.5,r,127.5,1)
		rectfill(l,32.5,r,127.5,13)
		rectfill(l,39.5,r,127.5,12)
		rectfill(l,65.5,r,127.5,11)
		rectfill(l,85.5,r,127.5,10)
		rectfill(l,96.5,r,127.5,9)
	end
	rectfill(l,103.5,r,127.5,9)
	rectfill(l,104.5,r,127.5,8)
	rectfill(l,109.5,r,127.5,2)
	pset(l,sky_y+0.5,0)
	pset(r,sky_y+0.5,0)
	if mode=="pong mode" then
		cls(0)
		local i
		for i=1,15 do
			line(64,7*i,64,7*i+2,7)
		end
	end
	if (mode=="blackout mode" and (game_frame==50 or game_frame==65 or game_frame>70)) then
		cls(0)
	end
	-- draw each entity
	foreach(entities,function(entity)
		if entity.render_layer<10 then
			entity:draw()
			pal()
		end
	end)
	-- draw rects so that nothing is rendered off screen
	rectfill(-10.5,-137.5,137.5,0.5,0)
	rectfill(-10.5,0.5,0.5,137.5,0)
	rectfill(127.5,0.5,137.5,137.5,0)
	rectfill(-10.5,ground_y+0.5,137.5,137.5,0)
	-- draw the corners
	pset(l,ground_y-0.5,0)
	pset(r,ground_y-0.5,0)
	pset(midpoint_x-0.5,ground_y-0.5,0)
	pset(midpoint_x+0.5,ground_y-0.5,0)
	-- draw ui entities
	foreach(entities,function(entity)
		if entity.render_layer>=10 then
			entity:draw()
			pal()
		end
	end)
	-- draw debug info
	-- camera()
	-- rect(0,0,127,127,3)
	-- print("scene:    "..scene,3,3,3)
	-- print("entities: "..#entities,3,10,3)
	-- print("speed:    "..ball_speed_rating,3,17,3)
end

function mark_ball_dropped(ball)
	ball:die()
	local player_num=ternary(ball.x+ball.width/2<midpoint_x,1,2)
	local juggler=jugglers[player_num]
	-- fudge the number of where the ball landed, to help convince the player they missed it
	-- shhhh don't tell, it's for the best! ;)
	local landing_x=ball.x
	if ball.x+ball.width/2<juggler.x+juggler.width/2 then
		landing_x=max(landing_x-3,left_wall_x)
	else
		landing_x=min(landing_x+3,right_wall_x-ball.width)
	end
	-- spawn an icon and an explosion of sparks where the ball landed
	local count_as_drop=true
	if mode=="bomb mode" then
		local dx=ball.x+ball.width/2-juggler.x-juggler.width/2
		if abs(dx)>13 then
			count_as_drop=false
			sfx(20,2) -- explosion
		end
		spawn_entity("ball_schwing",ball.x,min(ball.y-9,ground_y-12),{
			frames_to_death=ternary(count_as_drop,10,6),
			flipped=rnd()<0.5,
			is_big=true
		})
	else
		local ball_icon=spawn_entity("ball_icon",landing_x,ground_y,{color=ball.color})
	end
	if count_as_drop then
		spawn_entity("ball_sparks",landing_x,nil,{color=ball.color})
		shake_screen(10)
		jugglers[player_num].score_track:add_mark(ball.color)
		sfx(8,1) -- drop
		if #juggler.score_track.marks>=max_marks then
			change_scene("game-end")
		end
	end
end

function change_scene(s)
	-- inform all the entities
	if scene!=s then
		scene=s
		foreach(entities,function(entity)
			entity:on_scene_change()
		end)	
	end
	-- and then do stuff based on the scene
	if scene=="title" then
		music(4) -- title music
	elseif scene=="title->game" then
		next_ball_id=1
		game_frame=0
		if title_screen.mode_select.mode_index==1 then
			mode=nil
		elseif title_screen.mode_select.mode_index==#modes then
			mode=modes[rnd_int(2,#modes-1)]
		else
			mode=modes[title_screen.mode_select.mode_index]
		end
		tip=tips[title_screen.mode_select.mode_index]
		spawn_entity("mode_notification",nil,nil,{
			frames_to_death=ternary(tip and mode,300,220),
		})
		ball_speed_rating=1
		if mode=="sudden death" then
			ball_speed_rating=10
		elseif mode=="speedball mode" then
			ball_speed_rating=100
		end
		ball_spawn_rate=ternary(mode=="bomb mode",2,1)
		local score_track1,score_track2
		if mode=="cooperative mode" then
			score_track1=spawn_entity("score_track",45)
			score_track2=score_track1
		else
			score_track1=spawn_entity("score_track",7)
			score_track2=spawn_entity("score_track",83)
		end
		if mode=="pong mode" then
			score_track1,score_track2=score_track2,score_track1
		end
		local spawner1,spawner2
		if mode=="sudden death" then
			spawner1=spawn_entity("ball_spawner",61,ground_y+3)
			spawner2=spawner1
		else
			local spawner_dx=ternary(mode=="leapfrog mode",15,0)
			spawner1=spawn_entity("ball_spawner",33+spawner_dx,ground_y+3)
			spawner2=spawn_entity("ball_spawner",90-spawner_dx,ground_y+3)
		end
		max_marks=5
		if mode=="sudden death" then
			max_marks=1
		end
		local juggler_width=ternary(mode=="noodle arms mode",36,18)
		local dx=ternary(mode=="pong mode",10,0)
		spawn_entity("juggler",8+dx,ground_y-entity_classes.juggler.height,{
			player_num=1,
			width=juggler_width,
			min_x=left_wall_x,
			max_x=midpoint_x,
			throw_dir=1,
			score_track=score_track1,
			spawner=spawner1
		})
		spawn_entity("juggler",120-juggler_width-dx,ground_y-entity_classes.juggler.height,{
			player_num=2,
			width=juggler_width,
			min_x=midpoint_x,
			max_x=right_wall_x,
			throw_dir=-1,
			score_track=score_track2,
			spawner=spawner2
		})
		if show_controls then
			show_controls=false
			spawn_entity("controls")
		end
		if mode=="cooperative mode" then
			spawn_entity("stopwatch")
		elseif mode!="speedball mode" and mode!="pong mode" then
			spawn_entity("speedometer")
		end
	elseif scene=="game-start" then
		if mode=="blackout mode" then
			sfx(39,3) -- blackout static
		end
	elseif scene=="game" then
		standstill_frames=220
		occasional_ball_spawn_frames=440
		next_occasional_ball_spawn=rnd_int(1,2)
	elseif scene=="game-end" then
		music(2) -- game-end
		spawn_entity("game_over_text_geysers")
	end
end

function spawn_entity(class_name,x,y,args,skip_init)
	local entity
	local the_class=entity_classes[class_name]
	if the_class.extends then
		entity=spawn_entity(the_class.extends,x,y,args,true)
	else
		-- create default entity
		entity={
			is_alive=true,
			is_paused=false,
			frames_alive=0,
			frames_to_death=0,
			update_priority=0,
			render_layer=0,
			x=x or 0,
			y=y or 0,
			vx=0,
			vy=0,
			width=0,
			height=0,
			add_to_game=noop,
			remove_from_game=noop,
			on_scene_change=noop,
			init=noop,
			update=function(self)
				self:apply_velocity()
			end,
			post_update=noop,
			draw=noop,
			draw_outline=function(self,color)
				rect(self.x+0.5,self.y+0.5,
					self.x+self.width-0.5,self.y+self.height-0.5,color or 8)
			end,
			die=function(self)
				if self.is_alive then
					self:on_death()
					self.is_alive=false
				end
			end,
			on_death=noop,
			apply_velocity=function(self)
				self.x+=self.vx
				self.y+=self.vy
			end
		}
	end
	-- add the class name
	entity.class_name=class_name
	-- add class properties/methods onto it
	local k,v
	for k,v in pairs(the_class) do
		entity[k]=v
	end
	-- add properties onto it from the arguments
	for k,v in pairs(args or {}) do
		entity[k]=v
	end
	if not skip_init then
		-- initialize it
		entity:init()
		add(new_entities,entity)
	end
	-- return it
	return entity
end

function add_new_entities()
	local entity
	for entity in all(new_entities) do
		add(entities,entity)
		entity:add_to_game()
		entity:on_scene_change()
	end
	new_entities={}
end

-- if condition is true return the second argument, otherwise the third
function ternary(condition,if_true,if_false)
	return condition and if_true or if_false
end

-- increment a counter, wrapping to 20000 if it risks overflowing
function increment_counter(n)
	return n+ternary(n>32000,-12000,1)
end

-- increment_counter on a property of an object
function increment_counter_prop(obj,k)
	obj[k]=increment_counter(obj[k])
end

-- decrement a counter but not below 0
function decrement_counter(n)
	return max(0,n-1)
end

-- decrement_counter on a property of an object, returns true when it reaches 0
function decrement_counter_prop(obj,k)
	if obj[k]>0 then
		obj[k]=decrement_counter(obj[k])
		return obj[k]<=0
	end
end

-- bubble sorts a list according to a comparison func
function sort(list,func)
	local i
	for i=1,#list do
		local j=i
		while j>1 and func(list[j-1],list[j]) do
			list[j],list[j-1]=list[j-1],list[j]
			j-=1
		end
	end
end

-- check to see if two axis-aligned rectangles are overlapping
function rects_overlapping(x1,y1,w1,h1,x2,y2,w2,h2)
	if type(x2)=="table" then
		x2,y2,w2,h2=x2.x,x2.y,x2.width,x2.height
	elseif type(y1)=="table" then
		x2,y2,w2,h2=y1.x,y1.y,y1.width,y1.height
	end
	if type(x1)=="table" then
		x1,y1,w1,h1=x1.x,x1.y,x1.width,x1.height
	end
	return x1+w1>x2 and x2+w2>x1 and y1+h1>y2 and y2+h2>y1
end

function draw_sprite(sx,sy,sw,sh,x,y,...)
	sspr(sx,sy,sw,sh,x+0.5,y+0.5,sw,sh,...)
end

function shake_screen(frames)
	screen_shake_frames=min(screen_shake_frames+frames,17)
end

-- returns a random integer between min_val and max_val, inclusive
function rnd_int(min_val,max_val)
	return flr(min_val+rnd(1+max_val-min_val))
end

function colorwash(c)
	local i
	for i=1,15 do
		pal(i,c)
	end
end

__gfx__
00000000000000007700077000000000000000000000002228ee0000444000000000000000000000000000000000000000000000000000000000000000000000
007770000011100077707770000700000000000000002888888ee0f9994400000000000000000000000000000003333330000000000000000000000000000000
07777700010001000777770000777000000000000e888888888eeff9999440000000000000000000000000003bbbbbbbbb300000000000000000000000000000
0777770001000100007770000777770000000eee88888888888eef99999940000fff00000000000000000033bbbbbbbbbbbb0000000000000000000000000000
07777700010001000777770000000000000eee88888888888eee0f9999994000fffff00000000000000003bbbbbbbbbbbbbb6000000000000000000000000000
0077700000111000777077700000000000eee8888888888ee000099999994000fffff0000000000000003bbbbbbbbbbbbbbb6000000000000000000000000000
0000000000000000770007700000000000e888888888888e0000099999990000f9999f00000000000000bbbbbbbbbbbbbbb66000000000000000000000000000
0000000000000000000000000000000000888888888888e00000f99999940000f999990000000000000bbbbbbbbbb66666666000000000000000000000000000
0000000000000000002222220000007002888888888888e000009999999000009999990000000000000bbbbbbbb60000666b3330000000000000000000222200
0000000000000000002222220000077002288882288888e000009999999000009999990000000000006bbbbbbb0000003333333300dddd000000000228888880
00000000333300000022222200007770022222222888888e0000999999900009999994000000000000bbbbbbb30003333333333300ddddd0000888888888888e
00000007777000000022222200077770022222002288888e0000999999f00009999990000000000000bbbbbbb000bbbbbbbbbb330ddcccc0028888888888888e
00001107777eeeee0022222200057770002220002288888e0004999999f00049999990000000000006bbbbbb3006bbbbbbbbbbb30dccccc102888888888888ee
70077717777300ee002222220000577000000000028888880004999999ff00499999f0000000000006bbbbbb3006bbbbbbbbbbbb0dccccc1028888888888eee0
7777777777711000002222220000057000000000028888880004499999ff04999999f0000000000006bbbbbb3006bbbbbb6bbbbb0dccccc1028888888ee00000
07771777777111000022222200000050000000000088888800044999999f9499999f00000000000006bbbbbb30066bbb666bbbbb0dccccc10288888000000000
0000011777777100002222220000000000000000008888880000499999999999999f00000000000006bbbbbb3000666666bbbbbb0cccccc10288888000000000
000007777777777007222222000000e00000000000888888800044999999999999f0000000000000006bbbbbb300000006bbbbbb0cccccc00888888000000000
00000777777177777722222200000ee00000000000e88888800004999999999999f000aaaaaa5500006bbbbbb3330000bbbbbbb00cccccc00888888000000000
0000077007701177702222220000eee00eeee00000e8888880000449999999999f00aaaaaaaaaa550066bbbbbbb333bbbbbbbbb00ccccc100888888822222000
033777700770000000222222000eeee0eeeee000000888888200004499999999f0aaaaaaaaaaaaa55006bbbbbbbbbbbbbbbbbb30dccccc100888888888882200
0000000007777330002222220000eee0eeeeee00000e888882000000449999f00aaaaaaaaaaaaaa555066bbbbbbbbbbbbbbbbb00cccccc000888888888888200
00007700000000000022222200000ee0ee888800000e88888200000000000000aaaaaaaaaaaaaaaa550066bbbbbbbbbbbbbbb000cccccc000888888888888200
000770003330ee0000222222000000e0ee888820000e88888200000000000007aaaaaaaaaaaaaaaa55000666bbbbbbbbbbb60000cccccc000888888888888000
000770033330ee000022222200000000e8888820000e8888822000000000000aaaaaaaaa5077aaa555000006666bbbbbb6600000cccccc0008888888eeee0000
00077707777e30000022222200000060e8888822000ee888822000000000007aaaaaaa500000005550000000066666600000000ccccccc00e888888200000000
00077717777300000022222200000660e8888822000ee88882200000000000aaaaaaa5000000007777700000000000000000000cccccc000e888888200000000
00017777777110000022222200006660e888888200eee88882200000000000aaaaaaa0000000777777770000000000000000000cccccc000ee88888200000000
00031777777111000022222200066660e888888200eee88882200000000007aaaaaa500005aaaaaa77777000000000000000001cccccc000ee88888200002220
000701777771110000222222000066600e8888822eeee88882200000000007aaaaaa5000aaaaaaaaaaaa700000000000000000ccccccd000ee88888222888222
000700077777711000222222000006600e8888888eee888822200000000007aaaaaa5007aaaaaaaaaaaaa00000000000000000ccccccd000ee88888888888822
000777777777777007222222000000600e88888888ee888822200000000007aaaaaa5007aaaaaaaaaaaaa00000000000000001cccccc0000ee88888888888822
0007777777717777772222222222222200e888888888888822200000000007aaaaaa50007aaaaaaaaaaaa0000000000000000ccccccd0000ee88888888888822
0000000007701177702222222222222200e888888888888222200000000007aaaaaaa500077aa55aaaaaa0000000000000000ccccccd0000ee88888888888820
00000000077000000022222222222222000e888888888882220000000000007aaaaaa5000000000aaaaaa0000000000000001cccccc000000ee88888eeeee000
000000000777733000222222222222220000888888888822220000000000007aaaaaaaa5000000aaaaaa0000000000000000ccccccd000000000000000000000
0000000000000000002222222222222200000088888822222000000000000007aaaaaaaa5555aaaaaaaa0000000000000001ccccccddd0000000000000000000
0000000000000000002222222222222200000000222222200000000000000007aaaaaaaaaaaaaaaaaaa00000000000000001cccccccddddd0000000000000000
00000000033330000022222222222222000000000000000000000000000000007aaaaaaaaaaaaaaaaa700000000000000001cccccccccddddddd000000000000
000011107777000ee0222222222222220000000011111111000000000000000007aaaaaaaaaaaaaaa70000000000000000011ccccccccccdddddd00000000000
700777117777eeeee022222222222222000000dccccccccc11100000000000000007aaaaaaaaaaaa02220000000000000000111cccccccccccddd00000000000
77777771777730000022220000700000000000dcccccccccccc1100000000000000000aaaaaaa70222222000000000000000011111cccccccccdd00000000000
07771777777710000022227000700070000000dccccccccccccc110000000000000000000000000888222000000000000000000111111ccccccdd00000000000
0003117777711100002222070000070000000dccccccccccccccc100000000000000000000000e8888822000000022220000000000111111cccd000000000000
0007000777771100002222000000000000000dcccccccccccccccc10000000000000000000000e88888222000008888220000000000011111110000000000000
0007777777777110002222000000000000000dccccccddddcccccc100000000000000000000008888888220000e8888220000000000000111100000000000000
0007777777777770072222000000007700000cccccc1000ddcccccc100006666660000000000e8888888220000e8888220077700000000000000000000000000
0000000007707777772200000000000f00000cccccc10000ddccccc100066666660000000000e888888822000e8888882077aaa5000000000fffffff00000000
000000000770017770220000000000f000000cccccc000000dccccc1000bbbbb6660000000008888888882200e888888207aaaa55000000fff9999999ff00000
000000000777733000220000000000f00000ccccccc000000dccccc100bbbbbbb660000000008888888882200e888888207aaaaa500000f99999999999ff0000
22222222222222222222000000000f000000cccccc1000000dccccc100bbbbbbbb660000000e88888888882008888888007aaaaa500009999999999999fff000
222222222222222222220f00000007000000cccccc0000000cccccc106bbbbbbbbb600000008888888888822e8888888007aaaaa500099999999999999fff000
2222222222222222222200f000007f000001cccccc0000011cccccc00bbbbbbbbbb660000008888888888822e8888882007aaaaa500099999999999999fff000
0bbb00aaa00099000880007f000770000001cccccc111111ccccccc00bbbbbbbbbbb6000000888888888888288888880007aaaaa50099999999999999fff0000
0bbbb0aaa009990088800007f0f770000001cccccc111ccccccccc006bbbbb3bbbbbb000008888888888888288888880007aaaaa500999999994444ffff00000
bbbbbaaaaa099900888000077f77f000000ccccccccccccccccccc006bbbbb3bbbbbb600008888888888888888888880007aaaaa504999999944000000000000
bbbbbaaaaa099900888000ff7777f000001cccccccccccccccccc000bbbbbb03bbbbbb00008888888e8888888888880000aaaaaa509999999900000000000000
bbbbbaaaa00999008880fffff777ff00001ccccccccccccccccd0006bbbbb303bbbbbb0002888888808888888888880000aaaaaa509999999400000000000000
0bbb0aaaa0099900888000ff777fffff001cccccccccccccddd00006bbbbb300bbbbbbb008888888e088888888888e0000aaaaaa509999999000000000044440
0bb000aaa00999008880000f7777ff00001ccccccdddddddd0000006bbbbb3003bbbbbb00888888800e888888888800000aaaaaaa09999999000000000444444
000000aaa00999008880000f77f77000011cccccdddd000000000066bbbbbb666bbbbbb308888888000888888888800000aaaaaa709999999000000000999444
000000aaa0099900888000077f0f7000011cccccdd00000000000066bbbbbb666bbbbbbb0888888e000e88888888e00000aaaaaa70999999940000000f999944
000000aa00099900888000077000f700011cccccdd0000000000006bbbbbbbbbbbbbbbbb3e888880000088888888000000aaaaaa7049999999000000f9999994
0000000000099000888000f700000f0001cccccddd0000000000066bbbbbbbbbbbbbbbbb3ee888e00000e888888e000000aaaaaa70099999999000fff9999994
000000000009900088800070000000f011cccccddd0000000000066bbbbbbbbbbbbbbbbb33eeeee0000008888880000005aaaaaa7009999999999ff999999994
0000000000000000888000f00000000011cccccddd0000000000066bbbbbb3333bbbbbbbb30eee0000000e8888e00000055aaaaa700099999999999999999990
000000000000000088800f000000000011ccccddd00000000000066bbbbb33333bbbbbbbb3300000000000eeee000000055aaaaa700099999999999999999900
000000000000000088000f000000000011ccccddd0000000000066bbbbbb3300066bbbbbb33000000000000000000000055aaaa7700009999999999999999400
00000000000000000800f0000000000011ccccddd0000000000066bbbbbb3300006bbbbbbb3300000000000000000000055aaaa7700000999999999999944000
000bb0000aa00009900000802222222211cccdddd0000000000066bbbbb333000066bbbbbb3300000000000000000000055aaaa7700000009999999994400000
00bbbb00aaaa0099990008882222222201ccddddd0000000000066bbbbb330000066bbbbbb3300000000000000000000055aaaa7700000000044444440000000
00bbbb00aaaa00999900088822222222000ddddd00000000000066bbbbb3300000666bbbbb3300000000000000000000055aaaa7700000000000000000000000
0bbbbb0aaaaa00999000888822222222000ddddd00000000000006bbbb33300000066bbbb33000000000000000000000055aaaa7700000000000000000000000
0bbbb00aaaa0099990008880222222220000ddd0000000000000003333333000000000333000000000000000000000000555aaa7700000000000000000000000
0bbbb00aaaa00999900088802222222200000000000000000000003333333000000000000000000000000000000000000555aaa7700000000000000000000000
00bb00aaaa0009990008880022222222000000000000000000000003333300000000000000000000000000000000000000555a77000000000000000000000000
000000aaaa0099990008880000ccccc002222222222222222222000000000000000000000000000000000000000000aaaaaaa000000000000000000aaaaaa000
000000aaa0009990000888000ccccccc022222222222222222220000000000000000000000000000000000000000aa1111111aaa0000000000000aa111111aa0
0000000000009990008880000ccccccc02222222222222222222000000000000000077770000000000000000000a111111111111a000000000000a11111111a0
00000000000099000088800000ccccc00222222222222222222200007770000777007777000000000000000000a11111111111111aa000000000a11aa111a11a
00000000000000000088800000000000022222222222222222227007700700700070777700000000000000000a11111111111111111aaa000000a11a111aa11a
0000000000000000008800000cc000cc022222222222222222227777000700700077777700000077000000000a11111aaaaaaa11111111aaa000a11111aaa11a
000000000000000000880000ccccccccc2222222222222222222077700070070000077770000070070000000a11111aaaaaaaaaaaa1111111aaaa11aaaaaa11a
0000000000000000000000000ccccccc02222222222222222222000000070070000077777700070070000000a11111aaaaaaaaaaaaaaaaa11111a11aaaaaa11a
000000bbb000000aaa0000000990000000887000722222222222000000007700007777770700070070077007a11111aaaaaaaaaaaaaaaaaaaaaaa11aaaaaa11a
00000bbbb00000aaaa0000009990000008887777722222222222000000000000007777770070070070777777a11111aaaaaaaaaaaaaaaaaaaaa1a11aaaaaa11a
0000bbbbb00000aaaa00000999900000888807770222222222220000000000000077007700077000077077700a11111aaaaaaa1111111111111aa11aaaaaa11a
0000bbbb00000aaaa000000999000000888007770222222222220000000000007777007700000000000000000a111111111111111111aaaaaaa0a11aaaaaa11a
0000bbbb00000aaaa0000099990000088880000000c02222222200000000000000000077770000000000000000a11111111111111aaa00000000a11aaaaaa11a
0000bbb00000aaaa000009999000008888000cc00ccc22222222000077000000000000000000000000000000000aa11111111aaaa00000000000a11aaaaaa11a
000000000000aaa000000999000000888000cccc0ccc2222222200077000000000000000000000000000000000000aaaaaaaa000000000000000a11aaaaaa11a
000000000000aa0000009999000008888000cccc00cc222222220007700000000000777700000000000000000ddddddd0220ddddddd000aaaa00a11aaaaaa11a
000000000000000000009990000008880000cccc00cc22222222000777000000770077770000000000000000d7777777d22d7777777d0a1111aaa11aaaaaa11a
000000000000000000009900000088880000cccc00cc22222222000077700007007077770000000000000000d777dd77d22d77ddd77da111aa11a11aaaaaa11a
000000000000000000000000000088800000cccc0ccc22222222000007770070007777770000000000000000d77d7777d22d77d7777da11aaaaaa11aaaaaa11a
0000000000000000000000000008880000000cc00ccc22222222000000007700000077777700000777000000d77ddd77d22d77dd777da11aaaaaa11aaaaaa11a
000000000000000000000000000880000000000000c022222222000000000000700077770700007000770000d7777d77d22d77d7777da111aa11a11aaaaaa11a
0000000bbbb00000000aaa000000009990000000008822222222000000000000777777770070070000077007d77dd777d22d77d7777d0a1111aaa11aaaaaa11a
0000000bbbb0000000aaaa000000099990000000888822222222000000000000777777770007700000077777d7777777d22d7777777d00aaaa00a11aa111a11a
000000bbbbb000000aaaaa000000999990000008888822222222000000000000000000770000000000007770ddddddddd22ddddddddd22222222a11a111aa11a
000000bbbb000000aaaaa00000099999000000888880222222220000000000000000007700000000000000001111111112211111111122222222a11111aaa11a
000000bbbb00000aaaaa000000999990000008888800222222220000000000000000007777000000000000000ddddddd022222222222222222220a11111111a0
000000000000000aaaa000000099990000000888000022222222000000000000000000000000000000000000d7777777d22222222222222222220aa111111aa0
000000000000000aa00000000999900000008880000022222222000000777000077000000000000000000000d7d777d7d2222222222222222222000aaaaaa000
0000000000000000000000000990000000088800000022222222000077700700700707777000000000000000d7dd77d7d222222200000567600000000aaaa000
0000000000000000000000000000000000888000000022222222700777000700700707777000000000000000d7d7d7d7d22222220000056760000000a1111a00
0000000000000000000000000000000008880000000022222222777770000700700707777000000000000000d7d77dd7d2222222000000550000000a111111a0
0000000000000000000000000000000008800000000022222222077700000700700777777000000000000000d7d777d7d2222222000066666600660a111111a0
0000000000bbb0000000000aaa00000000009990000000000888000000000077000077770000000000000000d7777777d222222200666ff1866656a11111111a
00000000bbbbb00000000aaaaa00000000999990000000088888000000000000700077777700000000000000ddddddddd2222222066efff1888660a11111111a
0000000bbbbbb0000000aaaaaa00000009999900000000888880000000000000777777770770000000000000333333333222222206eeeff1888860a111aa111a
0000000bbbbb0000000aaaaaa000000999999000000088888800000000000000777777770007777700077007222222222222222266eeeff1888966a11aaaa11a
0000000bbbb0000000aaaaa0000000999990000000888888000000000000000000000077000000007777777722222222222222225eeeeef1899996a11aaaa11a
000000000000000000aaa000000009999900000008888880000000000000000000000077000000000000777022222222222222225dddeee1999996a11aaaa11a
000000000000000000000000000009990000000088888000000000000000000000000077770000000000000022222222222222225dddddcaaa9996a11aaaa11a
000000000000000000000000000000000000000888800000000022222222222222222222222222222222222222222222222222225ddddccbaaaaa6a11aaaa11a
0000000000000000000000000000000000000008800000000000222222222222222222222222222222222222222222222222222255dccccbbaaa66a11aaaa11a
00000000000bbb000000000000aaa00000000000009900000000000088802222222222222222222222222222222222222222222205ccccbbbaaa600a11aa11a0
000000000bbbbbb000000000aaaaaa00000000099999900000000088888822220ddddddddddddddddddddddddd00ddddddd02222055cccbbbba6600a11aa11a0
00000000bbbbbbb0000000aaaaaaaa0000000999999990000008888888802222d7777777777777777777777777dd7777777d222200555cbbb666000a11aa11a0
00000000bbbbbb0000000aaaaaaaa00000099999999900008888888880002222d77d77777dd7d7d7d7dd7ddd77dd777d777d2222000055566600000a11aa11a0
000000000bbb000000000aaaaaa0000000999999900000888888880000002222d77d77777d77d7d7d7d777d777dd777dd77d22222222222222222200a1aa1a00
000000000000000000000aaa0000000000999900000000888880000000002222d77d77dd7dd7ddd7d7dd77d777dd777ddd7d2222222222222222222222222222
00000000000bbb00000000000000aa0000000000000000000000000000000000d77d777777d7d7d7d7d777d777dd777dd77d2222222222222222222222222222
0000000000bbbbbb0000000aaaaaaaaa00000099999999990088888888888888d77dd7777dd7d7d7d7d777d777dd777d777d2222222222222222222222222023
000000000bbbbbbb000000aaaaaaaaaa00009999999999998888888888888888d7777777777777777777777777dd7777777d2222222222222222222222224567
000000000bbbbbbb000000aaaaaaaaaa00009999999999900888888888888880dddddddddddddddddddddddddddddddddddd22222222222222222222222289ab
00000000000bbbb00000000000aaaa0000000000000000000000000000000000333333333333333333333333333111111111222222222222222222222222cdef
__sfx__
010b00000b0100c0210e02113031180411d041210412404126041280412a0412b0412b0312b0212b0110000000000000000000000000000000000000000000000000000000000000000000000000000000000000
010600000b0100c0210e02113031180411d041210412404126041280412a0412b0412b0312b0212b0110000000000000000000000000000000000000000000000000000000000000000000000000000000000000
010400000b0100c0210e02113031180411d041210412404126041280412a0412b0412b0312b0212b0110000000000000000000000000000000000000000000000000000000000000000000000000000000000000
010200000b0100c0210e02113031180411d041210412404126041280412a0412b0412b0312b0212b0110000000000000000000000000000000000000000000000000000000000000000000000000000000000000
010b00002b0102b0212b0312a031280312603124031210311d03118021130210e0210c0210b0210b0110b01100000000000000000000000000000000000000000000000000000000000000000000000000000000
010600002b0102b0212b0312a031280312603124031210311d03118021130210e0210c0210b0210b0110b01100000000000000000000000000000000000000000000000000000000000000000000000000000000
010400002b0102b0212b0312a031280312603124031210311d03118021130210e0210c0210b0210b0110b01100000000000000000000000000000000000000000000000000000000000000000000000000000000
010200002b0102b0212b0312a031280312603124031210311d03118021130210e0210c0210b0210b0110b01100000000000000000000000000000000000000000000000000000000000000000000000000000000
0104000034640286311e24018231142310f2310d2310c2310a2310823107231042210322103211022110121100200002000020000200002000020000200002000020000200002000020000200002000020000200
010400000c7300d751127511a73100700007000070000700007000070000700007000070000700007000070000700007000070000700007000070000700007000070000700007000070000700007000070000700
010400001911113131151211e1112b111001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100
010400001b12113131251313111100100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000000
010400002d03033532335223352233512005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000000000000000000000000000000000000000000
01040000270302d041335423353233532335223351233512335120050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000000000000000000000
0104000023020270312d0513356233552335423353233522335123351233512335123351200500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500
010600002c1422c1422b1422a15229152281522715226152251522315222152201521e1421b142191421613213132171401713117121171110010000100001001713017121171110010000100001000010000100
01060000071420714208142091520a1520c1520e152101521315215152181521a1521e14220142231422513226132231402313123121231110010000100001002313023121231110000000000000000000000000
010700002b7222873226742247522b7522875226752247522b7522875226752247522b7522875226752247522b7522875226752247522b7522875226752247522b7522875226752247222b712007000070000700
010700000070000700007002b7222875226752247522b7522875226752247522b752287522675200700007000070026752247522b752287522675200700007000070026752247120070000700007000070000700
000500001e0401e0211e0211e01100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
010800001c64010631046310462104611000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
010600001e120201311f1411c1411a131191211b1311f141241510010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100
000600001e120201311f1411c1411a131191211a13118141141510010000100001000010000100001000010000000000000000000000000000000000000000000000000000000000000000000000000000000000
010c00001815018111001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100
010e00002b7502b74128740287312674026731247402473126740267312673126721247002470024700247002b7502b7412874028731267402474026740267212475024741247312472124700007000070000700
010e00002975029741297412973124750247412474124731217502174121741217312475024741247412473126750267412674126731267312672126721267112875028751287512875128741287410070000000
010e0000247502474121740217312474524745217402173129750297412474024731217452173524740247312674026731267312672128740287412873128731297502974129741297312a7502a7422a7422a741
010700200c5200c5200c5200c5201352013520135201352007520075200752007520135201352013520135200c5200c5200c5200c520135201352013520135200752007520075200752013520135201352013520
010700200c5200c5200c5200c5201552015520155201552005520055200552005520155201552015520155200c5200c5200c5200c520155201552015520155200552005520055200552015520155201552015520
010700200050000500005000050010520105211052110521005000050000500005001052010521105211052100500005000050000500105201052110521105210050000500005000050010520105211052110521
010700200050000500005000050011520115211152111521005000050000500005001152011521115211152100500005000050000500115201152111521115210050000500005000050011520115211152111521
010e00000060000600006000060000600006000000000000000000000000600006000060000600006000060000600006001c625006001c6250060000600006000060000600286250060028625000000000000000
010e000000000000001c6250000000000000001c62500000000000000000000000001c6251c625000000000000000000001c6250000000000000001c6250000000000000001c625000001c6251c6250000000000
010e00001c625000001c6250000000000000001c625000001c6251c6251c625000001c6250000000000000001c6250000000000000001c62500000000000000000000000001c6251c6251c625000000000000000
010700000000000000000000000000000000000000000000247202472124721247112471124711000000000026730267212672126721267212671126711000002874028731287312873128731287212872128711
011c00000c7100c7100c7100c7001371013710137101370007710077100771007700137101371013710137000c7100c7100c7100c700137101371013710137000771007710077100770013710137101371013700
011c00000c7100c7100c710000001571015710157100000005710057100571000000157101571015710000000c7100c7100c71000000157101571015710000000571005710057100000015710157101571000000
010400000e5350c500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000000
010400000c5350c500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
010700000621006210062200622006230062300624006240062400624006240062400624006245062450625500000062300624006240062400624006240062450625500000062300625500000062500000000000
011400000c1453c100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100
010700200c5200c5200c5200c5201354313520135201352007520075200752007520135431352013520135200c5240c5200c5200c520135431352013543135100754307520075200752013543135201352013520
010e00001c6250000000000000000c2300822104221042111c625000001c625000000421004221082210c2311c6250000000000000000c2300822104221042111c625000000c2301c6250c230082210422104211
010e00001c6251c6251c625000001c6250000000000000000c230082311c625000001c625000001c625000000c230082311c6250000005230012311c6250000002230002311c6251c62504230002311c62500000
010700200c5200c5200c5200c5201554315520155201552005520055200552005520155431552015520155200c5200c5200c5200c520155431552315523155230552005520055200552015543155201552015520
010e00001c6250000000000000001c6230000000000000001c625000001c625000001c625000001c625000001c6251c6251c6251c6251c6251c6251c6251c62510625106251c6251c62528625286353463534635
__music__
04 0f424344
04 10424344
01 11424344
04 12424344
00 22424344
01 181b5d44
00 191c1e1f
00 181b1d20
00 1a1c1e21
00 18296b2a
00 192c5e2b
00 18291d6d
02 1a2c5e2d

