%% PDSCH transmitter and receiver processing chain
%% Modified pdsch transmission chain using instantanous snr measured from decoded pdsch TB

d_bler = [];
trans_delay = [];
m_bler = []; 
video_list = dir('../video_bins/BigBuckBunny/*.txt');
leng_vid = length(video_list);
snr_off = 0;
RB_granu = 8;
soft_ack_true = 1;
a = 1.285;
BLER_snr = [];
bler_tmp = [];
laten = [];
rb_ratio = [];
past_en = 1;
state_buffer = zeros(5,2);
for SNRdB = -5:3:30
for i = 2  %:length(video_list)      % iterate through all videos
%video=['../video_bins/BigBuckBunny/',video_list(i).name];
video = '../video_bins/BigBuckBunny/720x480_fps30_420_1750k_bin.txt';
disp(['Tested video: ' video_list(i).name]);
RB = [];
log_snr_ = [];
log_snr_olla = [];
for max_dev = 3      % iterate through possible max_dev  4
disp("Maximum deviation for olla is: "+(max_dev));
for do_shift = 10  % simulate on different dopper shift
disp("Test on: "+(do_shift)+"Hz");
%video = '../video_bins/BigBuckBunny/384x288_fps30_420_375k_bin.txt';   % read videos from its binary stream
BW_expand = 30;   % BW estimate horizon  
acc_tbs = 0; % accumulated tbs size for bandwidth estimation
latency = 8; % latency constraint for transmission 
thrpt = 10;
th = [];
log_ = [];
Pr_list = [];

%% Simulation Parameters
u_d_ratio = 1;         % uplink and downlink transmission ratio
perfectEstimation = false; % Perfect synchronization and channel estimation
rng("default");            % Set default random number generator for repeatability
%img = './dataset/peppers.png'; % Test image
carrier = nrCarrierConfig;  % Carrier configuration  default: 15kHz scs, 52 grid size 
show_cons = false;          % Show constellation diagram
MCStable = [2,120;2,157;2,193;2,251;2,308;2,379;2,449;2,526;2,602;2,679; ...
    4,340;4,378;4,434;4,490;4,553;4,616;4,658; ...
    6,438;6,466;6,517;6,567;6,616;6,666;6,719;6,772;6,822;6,873;6,910;6,948];  % MCS table
fileID=fopen('./result/log.txt','w+');   % log file to record the result
cqi_table = [2,78;2,120;2,193;2,308;4,449;4,616;6,378;6,567;6,666;6,772;6,873;8,682.5;8,797;8,885;8,948];
SINR_REF = [-6.936, -5.147, -3.18, -1.253, 0.761, 2.699, 4.694, 6.520, 8.573, 10.3660, 12.2890, 14.1730, 15.8880, 17.8140, 19.8290];
%SINR_REF = [-6.7, -4.7, -2.3, 0.2, 2.4, 4.3, 5.9, 8.1, 10.3, 11.7, 14.1, 16.3, 18.7, 21, 22.7];
beta_list = [5, 5.01, 0.84, 1.67, 1.61, 1.64, 3.87, 5.06, 6.4, 12.6, 17.6, 23.3, 29.5, 33.0, 35.4];
% log_snr_ = [];
% log_snr_olla = [];
%% parameters for OLLA
snr_off = 0;
delta = 0.4;
%max_dev = 1.8;

%% CQI SNR initialization
%SNRdB = 8;   % avg snr
amp_noise = 1/(10^(SNRdB/20));
init_diff = abs(SINR_REF - SNRdB);
snr_avg = SNRdB;
cqi_t = find(init_diff == min(init_diff)); 

beta = beta_list(cqi_t);


%% PDSCH and DL-SCH configuration
pdsch = nrPDSCHConfig;
pdsch.NumLayers = 2;   % Set according to DCI RI

% Set DM-RS to improve channel estimation
pdsch.DMRS.DMRSAdditionalPosition = 1;
pdsch.DMRS.DMRSConfigurationType = 1;
pdsch.DMRS.DMRSLength = 2;
%pdsch.DMRS                            % Display DM-RS properties

% HARQ
NHARQProcesses = 16;     % Number of parallel HARQ processes
rvSeq = [0 2 3 1]; % Set redundancy version vector
% rvSeq = 0; % No harq
harq_state = zeros(NHARQProcesses,4);   % slot state blksize cqi
% HARQ management
harqEntity = HARQEntity(0:NHARQProcesses-1,rvSeq,pdsch.NumCodewords);  % Process, redundancy version, codewords

 % Create DL-SCH encoder object
encodeDLSCH = nrDLSCH;
encodeDLSCH.MultipleHARQProcesses = true;


% Create DL-SCH decoder object
decodeDLSCH = nrDLSCHDecoder;
decodeDLSCH.MultipleHARQProcesses = true;
% LDPC parameters
decodeDLSCH.LDPCDecodingAlgorithm = "Normalized min-sum";
decodeDLSCH.MaximumLDPCIterationCount = 10;


%% Channel Modeling
nTxAnts = 2;   % Number of transmit antennas
nRxAnts = 2;   % Number of receive antennas

% Check that the number of layers is valid for the number of antennas
if pdsch.NumLayers > min(nTxAnts,nRxAnts)
    error("The number of layers ("+string(pdsch.NumLayers)+") must be smaller than min(nTxAnts,nRxAnts) ("+string(min(nTxAnts,nRxAnts))+")")
end

% Create a channel object
channel = nrTDLChannel;
channel.DelayProfile = "TDL-C";    % Tapped delay line channel, C type
channel.MaximumDopplerShift = do_shift;
channel.NumTransmitAntennas = nTxAnts;
channel.NumReceiveAntennas = nRxAnts;

% Set the channel sample rate to that of the OFDM signal
ofdmInfo = nrOFDMInfo(carrier);
channel.SampleRate = ofdmInfo.SampleRate;

% Channel constellation diagram
constPlot = comm.ConstellationDiagram;                                          % Constellation diagram object
constPlot.ReferenceConstellation = getConstellationRefPoints(pdsch.Modulation); % Reference constellation values
constPlot.EnableMeasurements = 1;                                               % Enable EVM measurements

% Initial timing offset
offset = 0;

estChannelGrid = getInitialChannelEstimate(channel,carrier); % Channel estimation


[tx, vid_len] = read_video(video);    % read video stream
tx_tb = [tx;tx;tx;tx;tx;tx;tx;tx; zeros(50000*1500,1)];

recv = [{}];     % Receive signal, a cell array
bler = [];       % Record BLER
bler_tmp = [];    % tem_bler for bandwidth calculation
nSlot = 0;
retrans_cnt = 0;
doppler_chge = 30;  % doppler variations per 30 slots

vid_track = 0;
end_flag = 0;
cnt_down = NHARQProcesses*3;  % count down of the transmission when the last slot has been sent


while true
%     if mod(nSlot,doppler_chge)
%         channel.MaximumDopplerShift = normrnd(10,4,1,1);      % sample the doppler frequency shift from Gaussian distribution periodically
%     end
    % select mcs according to current cqi
    mo_order = cqi_table(cqi_t,1);
    
    if pdsch.NumCodewords == 1   
        codeRate = cqi_table(cqi_t,2)/1024;
    else
        codeRate = [cqi_table(cqi_t,2) cqi_table(cqi_t,2)]./1024;
    end
    encodeDLSCH.TargetCodeRate = codeRate;
    decodeDLSCH.TargetCodeRate = codeRate;

    % New slot
    carrier.NSlot = nSlot;
    % Generate PDSCH indices info, which is needed to calculate the transport
    % block size
    [pdschIndices,pdschInfo] = nrPDSCHIndices(carrier,pdsch);
    %% Record history data
     if past_en
            state_buffer(mod(length(log_),length(state_buffer))+1,1) = snr_avg;
            state_buffer(mod(length(log_),length(state_buffer))+1,2) = cqi_t;
     end
    %% Reallocate RBs
    Xoh_PDSCH = 0;
    if past_en
        snr_pr = sum(state_buffer(:,1))/length(state_buffer);
        cqi_pr = ceil(sum(state_buffer(:,2)/length(state_buffer)));
    else
        snr_pr = snr_avg;
        cqi_pr = cqi_t;
    end
    Pr = 1/2 * ((erf((snr_pr-SINR_REF(cqi_pr)+a)/sqrt(2))+1));   % Probability of successfully receiving the block
    if ~mod(length(log_),RB_granu)
        %Pr = 1/2 * ((erf((snr_avg-SINR_REF(cqi_t)+a)/sqrt(2))+1));   % Probability of successfully receiving the block
        baseline_ = vid_len / (1e3*latency*Pr);
        %baseline_ = 62592712/ (1e3*latency*Pr);
        tb_ = [];
            for ind = 5:(carrier.NSizeGrid-1)
                pdsch.PRBSet = 0:ind;     
                trBlkSizes = nrTBS(pdsch.Modulation,pdsch.NumLayers,numel(pdsch.PRBSet),pdschInfo.NREPerPRB,codeRate,Xoh_PDSCH);
                tb_ = [tb_ ,trBlkSizes];
            end
        tb_diff = abs(tb_ - baseline_);
        ind = find(tb_diff == min(tb_diff))+5-1 ;
        disp("Index is "+(ind));
        pdsch.PRBSet = 0:ind;   % Band allocation
        %pdsch.PRBSet = 0: 51;
        trBlkSizes = nrTBS(pdsch.Modulation,pdsch.NumLayers,numel(pdsch.PRBSet),pdschInfo.NREPerPRB,codeRate,Xoh_PDSCH);
        newPrecodingWeight = getPrecodingMatrix(pdsch.PRBSet,pdsch.NumLayers,estChannelGrid);  % Precoding matrix, set according to DCI
    end
    
    %% Get new transport blocks and flush decoder soft buffer, as required
    for cwIdx = 1:pdsch.NumCodewords
        if harqEntity.NewData(cwIdx)   % check whether this is a new data; start of the redundancy version
            % Create and store a new transport block for transmission
            if vid_track+trBlkSizes >= length(tx_tb)
               trBlk = zeros(trBlkSizes,1);
               trBlk(1:length(tx_tb)-vid_track) = tx_tb(vid_track+1:length(tx_tb));  % padding zeros
               end_flag = 1;
            else
               trBlk = tx_tb(vid_track+1:vid_track+trBlkSizes);    
            end
            setTransportBlock(encodeDLSCH,trBlk,cwIdx-1,harqEntity.HARQProcessID);

            % If the previous RV sequence ends without successful
            % decoding, flush the soft buffer
            if harqEntity.SequenceTimeout(cwIdx)
                resetSoftBuffer(decodeDLSCH,cwIdx-1,harqEntity.HARQProcessID);
            end
        end
    end
    codedTrBlock = encodeDLSCH(pdsch.Modulation,pdsch.NumLayers,pdschInfo.G,harqEntity.RedundancyVersion,harqEntity.HARQProcessID);
    %% PDSCH Modulation and MIMO
    pdschSymbols = nrPDSCH(carrier,pdsch,codedTrBlock);
    % DM-RS symbols generation
    dmrsSymbols = nrPDSCHDMRS(carrier,pdsch);
    dmrsIndices = nrPDSCHDMRSIndices(carrier,pdsch);
    precodingWeights = newPrecodingWeight;
    pdschSymbolsPrecoded = pdschSymbols*precodingWeights;

    % Resource grid mapping
    pdschGrid = nrResourceGrid(carrier,nTxAnts);
    [~,pdschAntIndices] = nrExtractResources(pdschIndices,pdschGrid);
    pdschGrid(pdschAntIndices) = pdschSymbolsPrecoded;

    % PDSCH DM-RS precoding and mapping
    for p = 1:size(dmrsSymbols,2)
        [~,dmrsAntIndices] = nrExtractResources(dmrsIndices(:,p),pdschGrid);
        pdschGrid(dmrsAntIndices) = pdschGrid(dmrsAntIndices) + dmrsSymbols(:,p)*precodingWeights(p,:);
    end

    [txWaveform,waveformInfo] = nrOFDMModulate(carrier,pdschGrid); % OFDM Modulation

    %% Pass thru TDL channel
    chInfo = info(channel);
    maxChDelay = ceil(max(chInfo.PathDelays*channel.SampleRate)) + chInfo.ChannelFilterDelay;
    txWaveform = [txWaveform; zeros(maxChDelay,size(txWaveform,2))];  % Padding zeros for delay flush
    
    [rxWaveform,pathGains,sampleTimes] = channel(txWaveform);
    noise = generateAWGN(SNRdB,nRxAnts,waveformInfo.Nfft,size(rxWaveform));
    rxWaveform = rxWaveform + noise;

    %% Perform perfect or practical timing estimation and synchronization
    if perfectEstimation
        % Get path filters for perfect timing estimation
        pathFilters = getPathFilters(channel); 
        [offset,mag] = nrPerfectTimingEstimate(pathGains,pathFilters);
    else
        [t,mag] = nrTimingEstimate(carrier,rxWaveform,dmrsIndices,dmrsSymbols);
        offset = hSkipWeakTimingOffset(offset,t,mag);
    end
    rxWaveform = rxWaveform(1+offset:end,:);

    %% Demodulation, channel estimation
    rxGrid = nrOFDMDemodulate(carrier,rxWaveform);   % OFDM-demodulate the synchronized signal
    
    if perfectEstimation
        % Perform perfect channel estimation between transmit and receive
        % antennas.
        estChGridAnts = nrPerfectChannelEstimate(carrier,pathGains,pathFilters,offset,sampleTimes);

        % Get perfect noise estimate (from noise realization)
        noiseGrid = nrOFDMDemodulate(carrier,noise(1+offset:end ,:));
        noiseEst = var(noiseGrid(:));

        % Get precoding matrix for next slot
        newPrecodingWeight = getPrecodingMatrix(pdsch.PRBSet,pdsch.NumLayers,estChGridAnts);

        % Apply precoding to estChGridAnts. The resulting estimate is for
        % the channel estimate between layers and receive antennas.
        estChGridLayers = precodeChannelEstimate(estChGridAnts,precodingWeights.');
    else
        % Perform practical channel estimation between layers and receive
        % antennas.
        [estChGridLayers,noiseEst] = nrChannelEstimate(carrier,rxGrid,dmrsIndices,dmrsSymbols,'CDMLengths',pdsch.DMRS.CDMLengths);

        % Remove precoding from estChannelGrid before precoding
        % matrix calculation
        estChGridAnts = precodeChannelEstimate(estChGridLayers,conj(precodingWeights));

        % Get precoding matrix for next slot
        newPrecodingWeight = getPrecodingMatrix(pdsch.PRBSet,pdsch.NumLayers,estChGridAnts);
    end

%% Plot channel estimate between the first layer and the first receive antenna
%        mesh(abs(estChGridLayers(:,:,1,1)));  
%        title('Channel Estimate');
%        xlabel('OFDM Symbol');
%        ylabel("Subcarrier");
%        zlabel("Magnitude");

        %% Equalization
        [pdschRx,pdschHest] = nrExtractResources(pdschIndices,rxGrid,estChGridLayers);
        [pdschEq,csi] = nrEqualizeMMSE(pdschRx,pdschHest,noiseEst);

        %% Constellation diagram
        if show_cons
         constPlot.ChannelNames = "Layer "+(pdsch.NumLayers:-1:1);
         constPlot.ShowLegend = true;
         % Constellation for the first layer has a higher SNR than that for the
         % last layer. Flip the layers so that the constellations do not mask
         % each other.
         constPlot(fliplr(pdschEq));
        end
         
        %% PDSCH and DL-SCH Decode
        [dlschLLRs,rxSymbols] = nrPDSCHDecode(carrier,pdsch,pdschEq,noiseEst);
         % Scale LLRs by CSI
        csi = nrLayerDemap(csi);                                    % CSI layer demapping
        for cwIdx = 1:pdsch.NumCodewords
            Qm = length(dlschLLRs{cwIdx})/length(rxSymbols{cwIdx}); % Bits per symbol
            csi{cwIdx} = repmat(csi{cwIdx}.',Qm,1);                 % Expand by each bit per symbol
            dlschLLRs{cwIdx} = dlschLLRs{cwIdx} .* csi{cwIdx}(:);   % Scale
        end
        csi_arr = cell2mat(csi);
        csi_arr = csi_arr(1,:);
        snr_list = 20.*log10(csi_arr/amp_noise);
       
        if harqEntity.TransmissionNumber == 0     % modified
            decodeDLSCH.TransportBlockLength = trBlkSizes;  
            acc_tbs = acc_tbs + trBlkSizes;
        else
            decodeDLSCH.TransportBlockLength = harqEntity.TransportBlockSize;
            acc_tbs = acc_tbs + harqEntity.TransportBlockSize;
        end

        [decbits,blkerr] = decodeDLSCH(dlschLLRs,pdsch.Modulation,pdsch.NumLayers, ...
        harqEntity.RedundancyVersion,harqEntity.HARQProcessID);
  
        bler = [bler, blkerr];
        bler_tmp = [bler_tmp, blkerr];
        %% calculate instantaneous snr for each transport block
        snr_avg = beta*(log(1/length(csi_arr)*sum(exp(snr_list/beta))));
        snr_measured = snr_avg;
      
        %% Soft_ACK
        if soft_ack_true
            if ~blkerr
                 if Pr < 0.75     % set the threshold
                     snr_off = max(-max_dev-4,snr_off-19*blkerr*delta);    % receive low-margin-ack
                 else 
                     snr_off = min(snr_off+(1-blkerr)*delta,max_dev);    % receive high-margin-ack
                 end
            else 
                snr_off = max(-max_dev-4,min(snr_off+(1-blkerr)*delta-19*blkerr*delta,max_dev));
            end

        else
            snr_off = max(-max_dev-4,min(snr_off+(1-blkerr)*delta-19*blkerr*delta,max_dev));
        end
        snr_avg = snr_avg + snr_off;
        diff = abs(SINR_REF - snr_avg);
        cqi_ts = find(diff == min(diff));  % mcs for the next tb
        if length(cqi_ts) >1
            cqi_t = cqi_ts(1);
        else
            cqi_t = cqi_ts;
        end
        % log snr, number of RBs
        log_snr_olla = [log_snr_olla, snr_avg];
        log_snr_ = [log_snr_, snr_measured];
        RB = [RB, ind];
        Pr_list = [Pr_list, Pr];
        %% HARQ report
        if harqEntity.TransmissionNumber == 0 
        %if harq_state(harqEntity.HARQProcessID+1,2) == 0
           statusReport = updateAndAdvance(harqEntity,blkerr,trBlkSizes,pdschInfo.G);
        else
           statusReport = updateAndAdvance(harqEntity,blkerr,harqEntity.TransportBlockSize,pdschInfo.G);
           %statusReport = updateAndAdvance(harqEntity,blkerr,harq_state(harqEntity.HARQProcessID+1,3),pdschInfo.G);
        end

        disp("Slot "+(nSlot)+". "+statusReport+ " CQI "+(cqi_t)+" SNR "+(snr_measured)+"dB"+" SNR offset "+(snr_off)+"Doppler shift: "+(channel.MaximumDopplerShift));
        
        log_ = [log_; nSlot];
        mod_flag = ~ mod(length(log_),50);

%         if mod_flag
%          tline=['Timestamp: ' num2str(time_ind) 'SNR: ' num2str(SNRdB) 'dB' ' Video: ' num2str(resolution) '  CQI: ' num2str(cqi_t)  ...
%          '  Throughput: ' num2str(thrpt) 'Mbps','\r\n'];
%          fprintf(fileID,tline);
%          time_ind = time_ind + 1;
%         end

        if ~ mod(length(log_),80)
            bler22 = length(bler_tmp(bler_tmp == 1))/length(bler_tmp);
            thrpt = (acc_tbs/(80*1e-3))*(1-bler22)/1e6;
            th = [th, thrpt];
            acc_tbs = 0;
            bler_tmp = []; 
        end

        if mod_flag
           %writecell({num2str(time_ind),num2str(SNRdB),num2str(resolution),num2str(cqi_t),num2str(thrpt),num2str(bler22)},'demo.xlsx','WriteMode','append');
           %writecell({SNRdB,resolution,cqi_t,thrpt,bler22},'demo.xlsx','WriteMode','append');
           %time_ind = time_ind + 1;
        end

        if contains(statusReport,'Initial')
            recv(nSlot+1) = {decbits};
            nSlot = nSlot + 1;    % Next slot
            vid_track = vid_track + trBlkSizes;  % track the video transmission position
        end
         %% Retransmission
         if contains(statusReport,'Retransmission')
             if contains(statusReport,'RV=2')
                 recv(log_(length(log_)-NHARQProcesses)+1) = {decbits};
             end
             if contains(statusReport,'RV=3')
                 recv(log_(length(log_)-NHARQProcesses*2)+1) = {decbits};
             end
             if contains(statusReport,'RV=1')
                 recv(log_(length(log_)-NHARQProcesses*3)+1) = {decbits};
             end
         end
         if vid_track >= vid_len
            cnt_down = cnt_down - 1;
         end
%          if cnt_down == 0
%              break;
%          end
%          if end_flag
%              break;
%          end
        if length(log_) > 8000
            break;
        end
% rx = [];
% for ii = 1:length(recv)
%     rx = [rx;cell2mat(recv(ii))];
% end
% rat_rb = sum(RB)/(length(RB)*51);
% [~,ratio] = biterr(rx(1:vid_len),tx(1:vid_len));
bler_all = length(bler(bler == 1))/length(bler);  
% d_bler = [d_bler,bler_all];
% trans_delay = [trans_delay, length(log_)];
end
% m_bler = [m_bler, bler_all];
end
rb_ratio = [rb_ratio, rat_rb];
laten = [laten,length(log_)/1000];
end
% laten = [laten,length(log_)/1000];
end
BLER_snr = [BLER_snr,bler_all];
end
