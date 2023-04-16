%% PDSCH transmitter and receiver processing chain
% DCI is read from 5g trace dataset

%tracepath = '/Users/evan/Desktop/5G-production-dataset/Amazon_Prime/Driving/Season3-TheExpanse/B_2019.12.03_07.29.22.csv';  % load 5g trace dataset
tracepath = '/Users/evan/Desktop/5G-production-dataset/Amazon_Prime/Driving/Season3-TheExpanse/B_2019.12.03_07.29.22.csv';
video = '../video_bins/BigBuckBunny/640x480_fps30_420_1050k_bin.txt';   % read videos from its binary stream
resolution = 5;   % video quality
BW_expand = 6;   % BW estimate horizon  
acc_tbs = 0; % accumulated tbs size for bandwidth estimation
thrpt = 10;
th = [];
%% Simulation Parameters
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
log = [];


%% PDSCH and DL-SCH configuration
pdsch = nrPDSCHConfig;
pdsch.NumLayers = 2;   % Set according to DCI RI
pdsch.PRBSet = 0:carrier.NSizeGrid-1;     % Full band allocation

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
decodeDLSCH.MaximumLDPCIterationCount = 6;


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
channel.MaximumDopplerShift = 2;
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
newPrecodingWeight = getPrecodingMatrix(pdsch.PRBSet,pdsch.NumLayers,estChannelGrid);  % Precoding matrix, set according to DCI

[tx, vid_len] = read_video(video);    % read video stream
tx_tb = [tx; zeros(50000*1500,1)];

recv = [{}];     % Receive signal, a cell array
bler = [];           % Record BLER
bler_tmp = [];    % tem_bler for bandwidth calculation
nSlot = 0;
retrans_cnt = 0;

%% Read cqi and mcs from 5g dataset
[time, snr, cqi] = load_5G_trace(tracepath); 
%cqi = [10,11,13,9,11,12,8,11,10,8,9,10,11,12,10,13,10,9,8,10];
time_ind = 540;   % simulation start time
vid_track = 0;
end_flag = 0;
cnt_down = NHARQProcesses*3;  % count down of the transmission when the last slot has been sent

while true
    SNRdB = str2num(snr(time_ind));
    %SNRdB = 12;
    cqi_t = str2num(cqi(time_ind));
    %cqi_t = cqi(time_ind);
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

    % Calculate transport block sizes
    Xoh_PDSCH = 0;
    trBlkSizes = nrTBS(pdsch.Modulation,pdsch.NumLayers,numel(pdsch.PRBSet),pdschInfo.NREPerPRB,codeRate,Xoh_PDSCH);
    

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

        %% HARQ report
        if harqEntity.TransmissionNumber == 0 
        %if harq_state(harqEntity.HARQProcessID+1,2) == 0
           statusReport = updateAndAdvance(harqEntity,blkerr,trBlkSizes,pdschInfo.G);
        else
           statusReport = updateAndAdvance(harqEntity,blkerr,harqEntity.TransportBlockSize,pdschInfo.G);
           %statusReport = updateAndAdvance(harqEntity,blkerr,harq_state(harqEntity.HARQProcessID+1,3),pdschInfo.G);
        end
%         id = mod((harqEntity.HARQProcessID+15),16)+1;
%         % assign state, success or fail
%         if contains(statusReport,'Initial')
%            harq_state(id,3) = trBlkSizes;
%            harq_state(id,1) = nSlot;
%            harq_state(id,4) = mo_order;
%         end
%         if contains(statusReport,'passed')
%            harq_state(id,2) = 0;     % initial passed, retrans passed
%         end
%         if contains(statusReport,'failed')
%             if contains(statusReport,'RV=1')   % three retransmissions failed
%                 harq_state(id,2) = 0;
%             else
%                 harq_state(id,2) = 1; % initial transmission failed; one, second retrans failed
%             end
%         end

        disp("Slot "+(nSlot)+". "+statusReport+ " CQI "+(cqi_t)+" SNR "+(SNRdB)+".");
        
        log = [log; nSlot];
        mod_flag = ~ mod(length(log),50);

%         if mod_flag
%          tline=['Timestamp: ' num2str(time_ind) 'SNR: ' num2str(SNRdB) 'dB' ' Video: ' num2str(resolution) '  CQI: ' num2str(cqi_t)  ...
%          '  Throughput: ' num2str(thrpt) 'Mbps','\r\n'];
%          fprintf(fileID,tline);
%          time_ind = time_ind + 1;
%         end

        if ~ mod(length(log),BW_expand*50)
            bler22 = length(bler_tmp(bler_tmp == 1))/length(bler_tmp);
            thrpt = (acc_tbs/(BW_expand*50*1e-3))*(1-bler22)/1e6;
            th = [th, thrpt];
            acc_tbs = 0;
            bler_tmp = []; 
        end

        if mod_flag
           %writecell({num2str(time_ind),num2str(SNRdB),num2str(resolution),num2str(cqi_t),num2str(thrpt),num2str(bler22)},'demo.xlsx','WriteMode','append');
           writecell({SNRdB,resolution,cqi_t,thrpt,bler22},'demo.xlsx','WriteMode','append');
           time_ind = time_ind + 1;
        end

        if contains(statusReport,'Initial')
            recv(nSlot+1) = {decbits};
            nSlot = nSlot + 1;    % Next slot
            vid_track = vid_track + trBlkSizes;  % track the video transmission position
        end
         %% Retransmission
         if contains(statusReport,'Retransmission')
             if contains(statusReport,'RV=2')
                 recv(log(length(log)-NHARQProcesses)+1) = {decbits};
             end
             if contains(statusReport,'RV=3')
                 recv(log(length(log)-NHARQProcesses*2)+1) = {decbits};
             end
             if contains(statusReport,'RV=1')
                 recv(log(length(log)-NHARQProcesses*3)+1) = {decbits};
             end
         end
         if vid_track >= vid_len
            cnt_down = cnt_down - 1;
         end
         if cnt_down == 0
             break;
         end
         if end_flag
             break;
         end
end
rx = [];
for ii = 1:length(recv)
    rx = [rx;cell2mat(recv(ii))];
end
[~,ratio] = biterr(rx(1:vid_len),tx(1:vid_len));
                                                                          
