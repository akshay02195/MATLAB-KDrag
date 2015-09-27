% *******************************************************************
% *   O_A_prop.m
% *   KDrag
% *   https://github.com/komrad36
% *
% *	9/26/2015
% *   This program is entirely my own work.
% *******************************************************************
%
% O_A_prop is a simple orbital and attitude propagator
% with B-dot, aero drag, and rotating orbital frame
% simulation for illustration of my aerodynamics model's
% behavior as well as for demonstrating the stability
% of a "dart" CubeSat design.

function O_A_prop
    addpath('igrf')
    addpath('KDrag')
    addpath('util')
    
    font_size = 13;
    time_span = 80000;
    
    % moment of inertia matrix
    global moi_matrix
    moi_matrix = [.038  0  0; 0 .04 0; 0 0 .0066667];
    
    % quat0 quat1 quat2 quat3 sat_ang_vel(wx wy wz)
    % Angular velocities are in radians/sec
    init_attitude = [1 0 0 0 .1 .25 .03]';
%     init_attitude = [1 0 0 0 .008 .005 .003]';
    
    % [rx ry rz vx vy vz] in the eci frame
    init_pos_vel = [6878 0 0 0 5.38 5.38]';
    
    % Processed vector is maintained in form:
    % [pos(x y z) vel(x y z) quat(q0 q1 q2 q3) ang_vel(wx wy wz)]
    
    state = [init_pos_vel; init_attitude]';
    
    all_times = zeros(20000, 1);
    time_idx = 2;
    
    all_states = [state; zeros(20000, 13)];
    state_idx = 2;
    
    options = odeset('RelTol',1e-13, 'MaxStep', 100); % error bound
    increment = 15; % Seconds between each orbital frame rotation
    tspan = [0 increment]; % integrate for specified time
    while tspan(1) < time_span  
        [time, state] = ode45(@(t, state) [state(4:6);
            -398600/norm(state(1:3))^3.*state(1:3);
            attitudeDiffEq(t, state)], tspan, state(end, :), options);

        all_times(time_idx:time_idx + numel(time) - 1) = time;
        time_idx = time_idx + numel(time);
        
        all_states(state_idx:state_idx + size(state, 1) - 1, :) = state;
        state_idx = state_idx + size(state, 1);
        
        tspan = [tspan(2), tspan(2) + increment];
        state(end, 7:10) = ...
            get_rel_quat(calc_orb_rot_quat(norm(state(end, 1:3)'),...
            increment), state(end, 7:10)');
    end
    
    num_pts = size(all_states, 1);

    subplot(4, 1, 1)
    set(gca, 'FontSize', font_size)
    plot(all_times, all_states(:,7:10))
    title('Orbital->Body Quaternion')
    ylabel('Quat Component')
    legend('q0', 'q1', 'q2', 'q3')

    subplot(4, 1, 2)
    set(gca, 'FontSize', font_size)
    plot(all_times, 60*all_states(:,11:13)/(2*pi))
    title('Satellite Angular Velocity')
    ylabel('Angular Velocity [rpm]')
    legend('\omega_x', '\omega_y', '\omega_z')
 
    long_ax = zeros(num_pts,3);
    for i = 1:num_pts
        long_ax(i,:) = v_rot_q([0; 0; 1], quat_inv(all_states(i, 7:10)'))';
    end
    pointing_err_ang = real(acosd(long_ax(:,1)/max(long_ax(:,1))));
    subplot(4, 1, 3)
    set(gca, 'FontSize', font_size)
    plot(all_times, long_ax)
    title('Satellite Long Axis Orientation in Orbital Frame')
    ylabel('Component')
    legend('x', 'y', 'z')
    
    subplot(4, 1 ,4)
    set(gca, 'FontSize', font_size)
    plot(all_times, pointing_err_ang)
    title('Satellite Pointing Error')
    ylabel('Degrees')
    ylim([0 180])
    xlabel('Time [s]')
end

% Compute quaternion associated with the orbital
% frame rotation that occurs after a given period of time
% for an orbit with a given semi major axis
function orb_rot_quat = calc_orb_rot_quat(semi_major, time_step)
    orbit_period = 2*pi*sqrt(semi_major^3/398600); % time of complete orbit
    angle_change = time_step/orbit_period*360;
    rot_vect = [0; -1; 0]; % -y axis
    
    % This quaternion specifies the orientation of the new orbital frame
    % relative to the old orbital frame after the given time_step
    orb_rot_quat = makequat(rot_vect, angle_change);
end

% Propagate attitude, considering aerodynamic torque and
% B-dot active velocity damping
% TODO: combine with orbit propagation for aero force
function state = attitudeDiffEq(t, state)
    global moi_matrix

    pos_quat = state(7:10)/norm(state(7:10));
    
    bdot_gain = -1e4;

    mag_field_body = get_mag_fld(state(1:3), state(4:6),...
        pos_quat, t, datenum([2015, 12, 12]));
    
    ang_vel = state(11:13);
    b_dot = cross(mag_field_body, ang_vel);
    des_mag_moment = bdot_gain*b_dot;
    % altitude of 500 km for now. see TODO above - will include aeroforce
    % for orbital decay
    [~, aero_torque] = KDrag(500, pos_quat, 135, norm(state(4:6)));
    torque = cross(des_mag_moment, mag_field_body) - aero_torque;
    ang_mom = moi_matrix*ang_vel;
    ang_accel = calc_ang_accel(torque, ang_vel, ang_mom, moi_matrix);
    
    state = [get_quat_der(state(7:13)); ang_accel];
end

% Compute magnetic field (in Tesla) relative to the
% body frame based on current orbital position and velocity, 
% the attitude quaternion (orbital to body) and the
% date and time
function mag_fld = get_mag_fld(position, velocity, pos_quat, time, date)
    lla = eci2lla(position, time);
    % North, East, Down components of the magnetic field vector
    % Convert from nanotesla to telsa
    mag_field_NED = (1e-9)*igrf(date, lla(1), lla(2),  lla(3))';
    gha = get_gha(time);
    
    % Direction cosine matrix from north-east-down to eci frame 
    ned2eci_dcm = ned_to_eci_dcm(lla(1), lla(2), gha);
    eci2orbital_dcm = eci_to_orbital_dcm(position, velocity);
    
    % magnetic field vector in the orbital frame 
    mag_field_orbital = ned2eci_dcm*eci2orbital_dcm*mag_field_NED;
    
    mag_fld = v_rot_q(mag_field_orbital, pos_quat);
end